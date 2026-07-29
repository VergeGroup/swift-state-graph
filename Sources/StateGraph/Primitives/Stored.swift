import Foundation

#if canImport(Observation)
  import Observation
#endif

/// A mutable source node that owns an in-memory value.
///
/// `Stored` is the primitive mutation boundary of a state graph. Reading its
/// value records graph dependencies, while assigning a value invalidates
/// dependents after releasing the node lock.
///
/// Persistence and external data sources should compose a `Stored` node rather
/// than replacing its value storage.
public final class Stored<Value: SendableMetatype>: Node, Observable, CustomDebugStringConvertible {

  public let lock: NodeLock

  nonisolated(unsafe)
  private var value: Value

  /// A typed staged value owned directly by this node during an outer graph transaction.
  ///
  /// The wrapper is deliberately not a reference box. `Stored` values are copyable today,
  /// but keeping the wrapper noncopyable makes its single owner explicit and lets commit
  /// consume the staged storage before publishing.
  private struct TransactionBuffer<Element>: ~Copyable {
    var value: Element

    init(_ value: consuming Element) {
      self.value = value
    }

    consuming func takeValue() -> Element {
      value
    }
  }

  /// Typed commit state moved out of the staging buffer before publication.
  ///
  /// Comparators evaluate this pending `(old, new)` pair while outside readers may
  /// still access the old committed graph. Publication later installs `newValue`
  /// and fills in the callback work under the short read barrier.
  private struct TransactionCommitWork {
    let oldValue: Value
    let newValue: Value
    var shouldNotify = false
    var trackingRegistrations: Set<TrackingRegistration> = []
    var outgoingEdges: ContiguousArray<Edge> = []
    var didSetHandler: ((Value, Value) -> Void)?
  }

  nonisolated(unsafe)
  private var transactionBuffer: TransactionBuffer<Value>?

  /// A typed value detached from a particular transaction during rollback.
  ///
  /// Multiple cleanup operations may overlap after their writer slots are released,
  /// so context identity keeps their node-local values distinct without moving them
  /// into the type-erased transaction context.
  private struct TransactionRollbackValue {
    let context: ObjectIdentifier
    let value: Value
  }

  /// Rolled-back values waiting to be destroyed outside writer coordination.
  nonisolated(unsafe)
  private var transactionRollbackValues: [TransactionRollbackValue] = []

  nonisolated(unsafe)
  private var transactionCommitWork: TransactionCommitWork?

  private let shouldNotify: @Sendable (Value, Value) -> Bool

#if canImport(Observation)
  @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
  private let observationRegistrar = ObservationRegistrar()
#endif

  public var potentiallyDirty: Bool {
    get {
      false
    }
    set {
      fatalError()
    }
  }

  public let info: NodeInfo

  public var wrappedValue: Value {
    get {
      if ThreadLocal.graphTransaction.value != nil {
        return transactionValue()
      }

      return GraphTransactionCoordinator.shared.withReadAccess {
        committedValue()
      }
    }
    set {
      if let transaction = ThreadLocal.graphTransaction.value {
        stage(newValue, in: transaction)
        return
      }

      GraphTransactionCoordinator.shared.withImmediateWrite {
        setImmediately(newValue)
      }
    }
  }

  /// Returns the transaction-visible value without adding committed graph edges.
  ///
  /// Body and comparator reads remain isolated. During synchronous callback delivery,
  /// Observation and graph-tracking passes may register directly with this leaf node.
  private func transactionValue() -> Value {
    let recordsDependencies =
      ThreadLocal.graphTransaction.value?.recordsDependencies == true

#if canImport(Observation)
    if recordsDependencies,
      #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    {
      observationRegistrar.access(
        NodeObservationRoot<Stored<Value>>(),
        keyPath: \NodeObservationRoot<Stored<Value>>.wrappedValue
      )
    }
#endif

    lock.lock()
    defer { lock.unlock() }

    if recordsDependencies, let registration = ThreadLocal.registration.value {
      trackingRegistrations.insert(registration)
    }

    if transactionBuffer != nil {
      return transactionBuffer!.value
    }

    // Comparators run before publication. Their thread-local transaction context
    // still reads the complete pending commit while outside readers see `value`.
    if let transactionCommitWork {
      return transactionCommitWork.newValue
    }

    return value
  }

  /// Returns the committed value and records ordinary graph and tracking dependencies.
  private func committedValue() -> Value {
#if canImport(Observation)
    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
      observationRegistrar.access(
        NodeObservationRoot<Stored<Value>>(),
        keyPath: \NodeObservationRoot<Stored<Value>>.wrappedValue
      )
    }
#endif

    lock.lock()
    defer { lock.unlock() }

    if let currentNode = ThreadLocal.currentNode.value {
      let edge = Edge(from: self, to: currentNode)
      outgoingEdges.append(edge)
      currentNode.incomingEdges.append(edge)
    }

    if let registration = ThreadLocal.registration.value {
      trackingRegistrations.insert(registration)
    }

    return value
  }

  /// Stages an assignment in this node's typed transaction buffer.
  private func stage(_ newValue: Value, in transaction: GraphTransactionContext) {
    lock.lock()
    let needsRegistration = transactionBuffer == nil
    let discardedBuffer = transactionBuffer.take()
    transactionBuffer = .init(newValue)
    lock.unlock()

    if needsRegistration {
      transaction.register(self)
    }

    Self.discardTransactionBuffer(discardedBuffer)
  }

  /// Ends a staged value's lifetime outside the node lock.
  private static func discardTransactionBuffer(
    _ buffer: consuming TransactionBuffer<Value>?
  ) {
    _ = consume buffer
  }

  /// Runs the existing immediate assignment pipeline after writer coordination.
  private func setImmediately(_ newValue: Value) {
    guard let immediateWriterScope = ThreadLocal.graphImmediateWriterScope.value else {
      preconditionFailure("Stored immediate mutation requires graph writer coordination.")
    }

    immediateWriterScope.nodeLockDepth += 1
    lock.lock()

    let oldValue = value

    guard shouldNotify(oldValue, newValue) else {
      value = newValue
      let didSetHandler = self.didSetHandler
      lock.unlock()
      immediateWriterScope.nodeLockDepth -= 1
      didSetHandler?(oldValue, newValue)
      return
    }

#if canImport(Observation)
    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
      withMainActor { [observationRegistrar] in
        observationRegistrar.willSet(
          NodeObservationRoot<Stored<Value>>(),
          keyPath: \NodeObservationRoot<Stored<Value>>.wrappedValue
        )
      }
    }

#endif

    value = newValue

    let outgoingEdges = self.outgoingEdges
    let trackingRegistrations = self.trackingRegistrations
    let didSetHandler = self.didSetHandler
    self.trackingRegistrations.removeAll()

    lock.unlock()
    immediateWriterScope.nodeLockDepth -= 1

    Self.publishGraphUpdates(
      trackingRegistrations: trackingRegistrations,
      outgoingEdges: outgoingEdges
    )

    didSetHandler?(oldValue, newValue)

#if canImport(Observation)
    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
      withMainActor { [observationRegistrar] in
        observationRegistrar.didSet(
          NodeObservationRoot<Stored<Value>>(),
          keyPath: \NodeObservationRoot<Stored<Value>>.wrappedValue
        )
      }
    }
#endif
  }

  func prepareTransactionCommit() {
    lock.lock()
    guard let transactionBuffer = self.transactionBuffer.take() else {
      lock.unlock()
      return
    }

    let oldValue = value
    let newValue = transactionBuffer.takeValue()
    transactionCommitWork = .init(
      oldValue: oldValue,
      newValue: newValue
    )

    lock.unlock()
  }

  func evaluateTransactionComparator() {
    lock.lock()
    guard let installedWork = transactionCommitWork else {
      lock.unlock()
      return
    }
    lock.unlock()

    // Every participant has moved its final value into node-local commit work.
    // Reentrant assignments see that coherent pending graph and stage into the
    // following commit batch.
    let shouldNotify = shouldNotify(
      installedWork.oldValue,
      installedWork.newValue
    )

    lock.lock()
    guard var transactionCommitWork else {
      lock.unlock()
      return
    }
    transactionCommitWork.shouldNotify = shouldNotify
    self.transactionCommitWork = transactionCommitWork
    lock.unlock()
  }

  func prepareTransactionObservationWillSet(
    _ observationWillSetDelivery: GraphTransactionObservationWillSetDelivery
  ) {
    lock.lock()
    guard transactionCommitWork?.shouldNotify == true else {
      lock.unlock()
      return
    }
    let outgoingEdges = self.outgoingEdges
    lock.unlock()

#if canImport(Observation)
    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
      observationWillSetDelivery.appendWillSetOperation { [observationRegistrar] in
        withMainActor {
          observationRegistrar.willSet(
            NodeObservationRoot<Stored<Value>>(),
            keyPath: \NodeObservationRoot<Stored<Value>>.wrappedValue
          )
        }
      }
    }
#endif

    for edge in outgoingEdges {
      observationWillSetDelivery.prepareWillSet(for: edge)
    }
  }

  func publishTransactionCommit() {
    lock.lock()
    guard var transactionCommitWork else {
      lock.unlock()
      return
    }

    value = transactionCommitWork.newValue
    transactionCommitWork.didSetHandler = didSetHandler
    self.transactionCommitWork = transactionCommitWork
    lock.unlock()
  }

  func prepareTransactionInvalidations(
    _ callbackDelivery: GraphTransactionCallbackDelivery
  ) {
    lock.lock()
    guard var transactionCommitWork else {
      lock.unlock()
      return
    }

    if transactionCommitWork.shouldNotify {
      transactionCommitWork.trackingRegistrations = trackingRegistrations
      transactionCommitWork.outgoingEdges = outgoingEdges
      trackingRegistrations.removeAll()
      self.transactionCommitWork = transactionCommitWork
    }
    lock.unlock()

    if transactionCommitWork.shouldNotify {
      for registration in transactionCommitWork.trackingRegistrations {
        callbackDelivery.append {
          registration.perform()
        }
      }

      for edge in transactionCommitWork.outgoingEdges {
        callbackDelivery.prepareInvalidation(for: edge)
      }
    }
  }

  func deliverTransactionCallbacks() {
    lock.lock()
    guard let transactionCommitWork = self.transactionCommitWork.take() else {
      lock.unlock()
      return
    }
    lock.unlock()

    transactionCommitWork.didSetHandler?(
      transactionCommitWork.oldValue,
      transactionCommitWork.newValue
    )

#if canImport(Observation)
    if transactionCommitWork.shouldNotify,
      #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    {
      withMainActor { [observationRegistrar] in
        observationRegistrar.didSet(
          NodeObservationRoot<Stored<Value>>(),
          keyPath: \NodeObservationRoot<Stored<Value>>.wrappedValue
        )
      }
    }
#endif
  }

  func prepareTransactionRollback(_ transaction: GraphTransactionContext) {
    lock.lock()
    guard let transactionBuffer = transactionBuffer.take() else {
      lock.unlock()
      return
    }
    transactionRollbackValues.append(
      .init(
        context: ObjectIdentifier(transaction),
        value: transactionBuffer.takeValue()
      )
    )
    lock.unlock()
  }

  func finishTransactionRollback(_ transaction: GraphTransactionContext) {
    let context = ObjectIdentifier(transaction)

    lock.lock()
    guard
      let index = transactionRollbackValues.lastIndex(
        where: { $0.context == context }
      )
    else {
      lock.unlock()
      return
    }
    let rollbackValue = transactionRollbackValues.remove(at: index)
    lock.unlock()

    Self.discardTransactionValue(rollbackValue.value)
  }

  /// Ends a rolled-back value's lifetime outside node and coordinator locks.
  private static func discardTransactionValue(_ value: consuming Value) {
    _ = consume value
  }

  /// Publishes graph invalidations captured while the node lock was held.
  ///
  /// Call this method only after releasing the node lock because tracking
  /// callbacks and edge updates may synchronously enter other graph nodes.
  private static func publishGraphUpdates(
    trackingRegistrations: Set<TrackingRegistration>,
    outgoingEdges: ContiguousArray<Edge>
  ) {
    for registration in trackingRegistrations {
      registration.perform()
    }

    for edge in outgoingEdges {
      edge.isPending = true
      edge.to?.potentiallyDirty = true
    }
  }

  public var incomingEdges: ContiguousArray<Edge> {
    get {
      fatalError()
    }
    set {
      fatalError()
    }
  }

  nonisolated(unsafe)
  public var outgoingEdges: ContiguousArray<Edge> = []

  nonisolated(unsafe)
  public var trackingRegistrations: Set<TrackingRegistration> = []

  nonisolated(unsafe)
  private var didSetHandler: ((Value, Value) -> Void)?

  public init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: StaticString? = nil,
    wrappedValue: consuming Value,
    shouldNotify: @Sendable @escaping (Value, Value) -> Bool
  ) {
    self.info = .init(
      name: name,
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.lock = .init()
    self.value = wrappedValue
    self.shouldNotify = shouldNotify

#if DEBUG
    Task { [weak self] in
      guard let self else { return }
      await NodeStore.shared.register(node: self)
    }
#endif
  }

  deinit {
    lock.lock()
    let outgoingEdges = self.outgoingEdges
    self.outgoingEdges.removeAll()
    lock.unlock()

    for edge in outgoingEdges {
      edge.to?.removeIncomingEdge(edge)
    }
  }

  public func recomputeIfNeeded() {
    // Stored nodes already own their current value.
  }

  public var debugDescription: String {
    let value = GraphTransactionCoordinator.shared.withReadAccess {
      lock.lock()
      defer { lock.unlock() }
      return self.value
    }

    let typeName = _typeName(type(of: self))
    return "\(typeName)(name=\(info.name.map(String.init) ?? "noname"), value=\(String(describing: value)))"
  }

  /// Mutates the stored value while holding the node's internal lock.
  ///
  /// This method bypasses the node's mutation pipeline. It does not emit StateGraph
  /// or Observation notifications, invalidate dependent nodes, or call the
  /// `onDidSet(_:)` handler.
  ///
  /// - Important: The mutation executes while the same lock that protects graph
  ///   bookkeeping is held. Calling node APIs or acquiring another node's lock from
  ///   `mutation` is unsupported and can introduce lock-order deadlocks.
  /// - Important: This method mutates committed storage even inside
  ///   ``withGraphTransaction(_:_:_:_:)``. The transaction does not stage or roll
  ///   back the mutation.
  ///
  /// Prefer assigning `wrappedValue`. Use this method only when the caller owns the
  /// lock ordering and intentionally does not require notifications.
  public borrowing func unsafeModify<Result, E>(
    _ mutation: (inout Value) throws(E) -> Result
  ) throws(E) -> Result where E: Error {
    if ThreadLocal.graphTransaction.value != nil {
      lock.lock()
      defer { lock.unlock() }
      return try mutation(&value)
    }

    return try GraphTransactionCoordinator.shared.withImmediateWrite {
      () throws(E) -> Result in
      guard let immediateWriterScope = ThreadLocal.graphImmediateWriterScope.value else {
        preconditionFailure("Stored unsafe mutation requires graph writer coordination.")
      }

      immediateWriterScope.nodeLockDepth += 1
      lock.lock()
      defer {
        lock.unlock()
        immediateWriterScope.nodeLockDepth -= 1
      }
      return try mutation(&value)
    }
  }

  /// Use `unsafeModify(_:)`; its name makes the notification and locking risks explicit.
  @available(*, deprecated, renamed: "unsafeModify")
  public borrowing func withLock<Result, E>(
    _ body: (inout Value) throws(E) -> Result
  ) throws(E) -> Result where E: Error {
    try unsafeModify(body)
  }

  /// Sets a closure to call after an assignment completes.
  public func onDidSet(_ handler: @escaping (Value, Value) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    didSetHandler = handler
  }
}

extension Stored: GraphTransactionParticipant {}

extension Stored {

  /// Creates a node that publishes every assignment.
  public convenience init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: StaticString? = nil,
    wrappedValue: consuming Value
  ) {
    self.init(
      file,
      line,
      column,
      name: name,
      wrappedValue: wrappedValue,
      shouldNotify: { _, _ in true }
    )
  }
}

extension Stored where Value: Equatable {

  /// Creates a node that publishes only when value equality changes.
  public convenience init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: StaticString? = nil,
    wrappedValue: consuming Value
  ) {
    self.init(
      file,
      line,
      column,
      name: name,
      wrappedValue: wrappedValue,
      shouldNotify: { $0 != $1 }
    )
  }
}

extension Stored where Value: AnyObject {

  /// Creates a node that publishes only when reference identity changes.
  public convenience init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: StaticString? = nil,
    wrappedValue: consuming Value
  ) {
    self.init(
      file,
      line,
      column,
      name: name,
      wrappedValue: wrappedValue,
      shouldNotify: { $0 !== $1 }
    )
  }
}

extension Stored where Value: Equatable & AnyObject {

  /// Creates a node that compares reference values by value equality.
  public convenience init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: StaticString? = nil,
    wrappedValue: consuming Value
  ) {
    self.init(
      file,
      line,
      column,
      name: name,
      wrappedValue: wrappedValue,
      shouldNotify: { $0 != $1 }
    )
  }
}
