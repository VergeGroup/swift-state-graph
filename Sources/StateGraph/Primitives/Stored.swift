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

  /// The latest typed value staged by one transaction scope, owned by this node.
  ///
  /// The wrapper is deliberately not a reference box. `Stored` values are copyable today,
  /// but keeping the wrapper noncopyable makes its single owner explicit and lets commit
  /// consume the staged storage before publishing.
  private struct TransactionBuffer<Element>: ~Copyable {
    var context: ObjectIdentifier
    var value: Element

    init(_ value: consuming Element, context: ObjectIdentifier) {
      self.context = context
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
  /// and captures graph invalidation work under the short read barrier.
  private struct TransactionCommitWork {
    let oldValue: Value
    let newValue: Value
    var shouldNotify = false
    var trackingRegistrations: Set<TrackingRegistration> = []
    var outgoingEdges: ContiguousArray<Edge> = []
  }

  /// Callback work captured by one immediate assignment before its reservation ends.
  ///
  /// The value is already published when this work is returned. Delivering it after
  /// the logical node reservation is released lets a same-node writer proceed while
  /// post-publication callbacks remain active, matching immediate assignment
  /// semantics without retaining the physical node lock.
  private struct ImmediateMutationDelivery {
    let oldValue: Value
    let newValue: Value
    let shouldNotify: Bool
    let trackingRegistrations: Set<TrackingRegistration>
    let outgoingEdges: ContiguousArray<Edge>
    let didSetHandler: ((Value, Value) -> Void)?
  }

  nonisolated(unsafe)
  private var transactionBuffer: TransactionBuffer<Value>?

  /// The staging state preceding a savepoint's first assignment to this node.
  ///
  /// `unstaged` is distinct from a staged optional `nil`. A saved value may belong
  /// to any ancestor because intermediate scopes need not have touched this node.
  private enum TransactionStagingState {
    case unstaged
    case staged(context: ObjectIdentifier, value: Value)
  }

  /// Typed undo state for a savepoint that has written this node.
  ///
  /// Read-only scopes allocate no node history. Successful scopes transfer their
  /// undo state to a previously untouched parent; rollback restores it directly,
  /// without invoking assignment observers or graph notifications.
  private struct TransactionSavepoint {
    let context: ObjectIdentifier
    let precedingState: TransactionStagingState
  }

  nonisolated(unsafe)
  private var transactionSavepoints: [TransactionSavepoint] = []

  /// A typed value detached by rollback or superseded by a savepoint merge.
  ///
  /// Multiple cleanup operations may overlap after their writer slots are released,
  /// so context identity keeps their node-local values distinct without moving them
  /// into the type-erased transaction context.
  private struct TransactionDiscardedValue {
    let context: ObjectIdentifier
    let value: Value
  }

  /// Values waiting for the entire scope to finish restoring or merging its nodes.
  /// Outer rollback also releases writer admission before destroying these values.
  nonisolated(unsafe)
  private var transactionDiscardedValues: [TransactionDiscardedValue] = []

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
      assertGraphMutationAllowed("Stored.wrappedValue mutation")

      if let transaction = ThreadLocal.graphTransaction.value {
        stage(newValue, in: transaction)
        return
      }

      let coordinator = GraphTransactionCoordinator.shared
      coordinator.withImmediateWrite(
        to: ObjectIdentifier(self),
        prepare: {
          prepareImmediateMutation(newValue)
        },
        deliver: { delivery in
          deliverImmediateMutation(delivery)
        }
      )
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

  /// Stages one assignment and then runs its assignment observer.
  ///
  /// `onDidSet(_:)` has the same per-assignment semantics inside and outside a
  /// transaction. The buffer is installed before the handler runs, so handler reads
  /// observe `newValue` and any `Stored` assignments it makes join the same ambient
  /// transaction. A later rollback discards all of those staged assignments, but it
  /// cannot undo non-`Stored` side effects already performed by the handler.
  private func stage(_ newValue: Value, in transaction: GraphTransactionContext) {
    lock.lock()

    let oldValue: Value
    if transactionBuffer != nil {
      oldValue = transactionBuffer!.value
    } else if let transactionCommitWork {
      // A synchronous Observation callback may assign while the preceding batch is
      // still being delivered. Its transaction-visible old value is that batch's
      // pending value, even when publication has not installed it yet.
      oldValue = transactionCommitWork.newValue
    } else {
      oldValue = value
    }

    let context = ObjectIdentifier(transaction)
    let needsRegistration = transactionBuffer == nil || transactionBuffer!.context != context
    var discardedBuffer = transactionBuffer.take()

    if needsRegistration, transaction.parent != nil {
      let precedingState: TransactionStagingState
      if let precedingBuffer = discardedBuffer.take() {
        let precedingContext = precedingBuffer.context
        precedingState = .staged(
          context: precedingContext,
          value: precedingBuffer.takeValue()
        )
      } else {
        precedingState = .unstaged
      }
      transactionSavepoints.append(
        .init(context: context, precedingState: precedingState)
      )
    }

    transactionBuffer = .init(newValue, context: context)
    let didSetHandler = self.didSetHandler
    lock.unlock()

    if needsRegistration {
      transaction.register(self)
    }

    Self.discardTransactionBuffer(discardedBuffer)
    didSetHandler?(oldValue, newValue)
  }

  /// Ends a staged value's lifetime outside the node lock.
  private static func discardTransactionBuffer(
    _ buffer: consuming TransactionBuffer<Value>?
  ) {
    _ = consume buffer
  }

  /// Publishes one immediate value while its logical node reservation is held.
  ///
  /// The physical lock protects only value and graph bookkeeping snapshots. The
  /// comparator and Observation `willSet` delivery run between those snapshots,
  /// while the coordinator reservation keeps competing same-node writers out.
  private func prepareImmediateMutation(
    _ newValue: Value
  ) -> ImmediateMutationDelivery {
    lock.lock()
    let oldValue = value
    lock.unlock()

    let shouldNotify = withGraphMutationProhibited(.storedComparator) {
      self.shouldNotify(oldValue, newValue)
    }

#if canImport(Observation)
    if shouldNotify,
      #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    {
      withMainActor { [observationRegistrar] in
        observationRegistrar.willSet(
          NodeObservationRoot<Stored<Value>>(),
          keyPath: \NodeObservationRoot<Stored<Value>>.wrappedValue
        )
      }
    }

#endif

    lock.lock()
    value = newValue

    let outgoingEdges = shouldNotify ? self.outgoingEdges : []
    let trackingRegistrations = shouldNotify ? self.trackingRegistrations : []
    let didSetHandler = self.didSetHandler
    if shouldNotify {
      self.trackingRegistrations.removeAll()
    }

    lock.unlock()

    return ImmediateMutationDelivery(
      oldValue: oldValue,
      newValue: newValue,
      shouldNotify: shouldNotify,
      trackingRegistrations: trackingRegistrations,
      outgoingEdges: outgoingEdges,
      didSetHandler: didSetHandler
    )
  }

  /// Delivers post-publication callbacks without a node lock or node reservation.
  private func deliverImmediateMutation(_ delivery: ImmediateMutationDelivery) {
    if delivery.shouldNotify {
      Self.publishGraphUpdates(
        trackingRegistrations: delivery.trackingRegistrations,
        outgoingEdges: delivery.outgoingEdges
      )
    }

    delivery.didSetHandler?(delivery.oldValue, delivery.newValue)

#if canImport(Observation)
    if delivery.shouldNotify,
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

  func prepareTransactionMerge(
    _ transaction: GraphTransactionContext,
    into parent: GraphTransactionContext
  ) {
    let context = ObjectIdentifier(transaction)
    let parentContext = ObjectIdentifier(parent)

    lock.lock()
    precondition(transactionBuffer != nil && transactionBuffer!.context == context)
    let savepoint = transactionSavepoints.removeLast()
    precondition(savepoint.context == context)

    // Keep the child's final value as the parent's staged value. Merging is not an
    // assignment and must not repeat onDidSet or publish a graph notification.
    transactionBuffer!.context = parentContext

    let needsParentRegistration: Bool
    switch savepoint.precedingState {
    case .unstaged:
      needsParentRegistration = true
    case .staged(let precedingContext, let precedingValue):
      if precedingContext == parentContext {
        needsParentRegistration = false
        // Retain the superseded parent value until every node has merged. Its deinit
        // must see the whole parent snapshot and must never execute under this lock.
        transactionDiscardedValues.append(.init(context: context, value: precedingValue))
      } else {
        needsParentRegistration = true
      }
    }

    if needsParentRegistration {
      if parent.parent != nil {
        // The parent had not written this node. It inherits the child's undo state,
        // including a value staged by an ancestor beyond the immediate parent.
        transactionSavepoints.append(
          .init(context: parentContext, precedingState: savepoint.precedingState)
        )
      } else {
        guard case .unstaged = savepoint.precedingState else {
          preconditionFailure("A root transaction cannot inherit another scope's staged value.")
        }
      }
    }
    lock.unlock()

    if needsParentRegistration {
      parent.register(self)
    }
  }

  func prepareTransactionCommit() {
    lock.lock()
    precondition(transactionSavepoints.isEmpty)
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
    let shouldNotify = withGraphMutationProhibited(.storedComparator) {
      self.shouldNotify(
        installedWork.oldValue,
        installedWork.newValue
      )
    }

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
    guard let transactionCommitWork else {
      lock.unlock()
      return
    }

    value = transactionCommitWork.newValue
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

  func deliverTransactionObservationDidSet() {
    lock.lock()
    guard let transactionCommitWork = self.transactionCommitWork.take() else {
      lock.unlock()
      return
    }
    lock.unlock()

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
    let context = ObjectIdentifier(transaction)
    precondition(transactionBuffer.context == context)
    transactionDiscardedValues.append(
      .init(
        context: context,
        value: transactionBuffer.takeValue()
      )
    )

    if transaction.parent != nil {
      let savepoint = transactionSavepoints.removeLast()
      precondition(savepoint.context == context)
      switch savepoint.precedingState {
      case .unstaged:
        break
      case .staged(let precedingContext, let precedingValue):
        self.transactionBuffer = .init(precedingValue, context: precedingContext)
      }
    } else {
      precondition(transactionSavepoints.isEmpty)
    }
    lock.unlock()
  }

  func finishTransactionCleanup(_ transaction: GraphTransactionContext) {
    let context = ObjectIdentifier(transaction)

    lock.lock()
    guard
      let index = transactionDiscardedValues.lastIndex(
        where: { $0.context == context }
      )
    else {
      lock.unlock()
      return
    }
    let discardedValue = transactionDiscardedValues.remove(at: index)
    lock.unlock()

    Self.discardTransactionValue(discardedValue.value)
  }

  /// Ends a discarded value's lifetime after the whole scope is coherent, outside locks.
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

  /// Returns this node's coordinator key outside generic mutation closure lowering.
  ///
  /// Keeping the identity conversion in a non-generic method also avoids a Swift
  /// 6.3 compiler crash when `ObjectIdentifier(self)` appears directly in the
  /// typed-throws `unsafeModify` implementation.
  private func coordinatorNodeIdentifier() -> ObjectIdentifier {
    ObjectIdentifier(self)
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
    NodeStore.shared.register(self)
#endif
  }

  deinit {
    lock.lock()
    let outgoingEdges = self.outgoingEdges
    self.outgoingEdges.removeAll()
    lock.unlock()

    for edge in outgoingEdges {
      edge.to?.sourceDidRelease(edge)
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
    assertGraphMutationAllowed("Stored.unsafeModify")

    if ThreadLocal.graphTransaction.value != nil {
      lock.lock()
      defer { lock.unlock() }
      return try withGraphMutationProhibited(.unsafeModification) { () throws(E) -> Result in
        try mutation(&value)
      }
    }

    let coordinator = GraphTransactionCoordinator.shared
    let node = coordinatorNodeIdentifier()
    return try coordinator.withImmediateWrite {
      () throws(E) -> Result in
      coordinator.beginImmediateNodeWrite(to: node)
      defer { coordinator.finishImmediateNodeWrite(to: node) }

      lock.lock()
      defer { lock.unlock() }
      return try withGraphMutationProhibited(.unsafeModification) { () throws(E) -> Result in
        try mutation(&value)
      }
    }
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
