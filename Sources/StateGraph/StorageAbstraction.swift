import Foundation

#if canImport(Observation)
  import Observation
#endif

// MARK: - Storage Protocol

/// A backing store used by a StateGraph stored node.
///
/// StateGraph reads and writes `value` while holding the owning node's lock. A value
/// accessor must not re-enter that node or access another StateGraph node because doing
/// so can violate lock ordering. Backing-store changes should be reported only through
/// the `StorageContext` received by `loaded(context:)`.
public protocol Storage<Value>: Sendable {
  
  associatedtype Value
      
  mutating func loaded(context: StorageContext)
  
  func unloaded() 
  
  var value: Value { get set }
  
}

public struct StorageContext: Sendable {
  
  private let onStorageUpdated: @Sendable () -> Void
    
  init(onStorageUpdated: @Sendable @escaping () -> Void) {
    self.onStorageUpdated = onStorageUpdated
  }
  
  public func notifyStorageUpdated() {
    onStorageUpdated()
  }
  
}

// MARK: - Concrete Storage Implementations

public struct InMemoryStorage<Value>: Storage {
  
  nonisolated(unsafe)
  public var value: Value
  
  public init(initialValue: consuming Value) {
    self.value = initialValue
  }
    
  public func loaded(context: StorageContext) {
    
  }
  
  public func unloaded() {
    
  }
    
}

public final class UserDefaultsStorage<Value: UserDefaultsStorable>: Storage, Sendable {
  
  nonisolated(unsafe)
  private let userDefaults: UserDefaults
  private let key: String
  private let defaultValue: Value
  
  nonisolated(unsafe)
  private var subscription: NSObjectProtocol?
  
  nonisolated(unsafe)
  private var cachedValue: Value?
  
  public var value: Value {
    get {
      if let cachedValue {
        return cachedValue
      }
      let loadedValue = Value._getValue(
        from: userDefaults,
        forKey: key,
        defaultValue: defaultValue
      )
      cachedValue = loadedValue
      return loadedValue
    }
    set {
      cachedValue = newValue
      newValue._setValue(to: userDefaults, forKey: key)
    }
  }
  
  nonisolated(unsafe)
  private var previousValue: Value?
  
  public init(
    userDefaults: UserDefaults,
    key: String,
    defaultValue: Value
  ) {
    self.userDefaults = userDefaults
    self.key = key
    self.defaultValue = defaultValue
  }
     
  public func loaded(context: StorageContext) {
    
    previousValue = value
    
    subscription = NotificationCenter.default
      .addObserver(
        forName: UserDefaults.didChangeNotification,
        object: userDefaults,
        queue: nil,
        using: { [weak self] _ in                      
          guard let self else { return }
          
          // Invalidate cache and reload value
          self.cachedValue = nil
          let value = self.value
          guard self.previousValue != value else {
            return
          }
          
          self.previousValue = value
          
          context.notifyStorageUpdated()
        }
      )
  }  
  
  public func unloaded() {
    guard let subscription else { return }
    NotificationCenter.default.removeObserver(subscription)
  }
}

// MARK: - Base Stored Node

/// A graph node backed by a pluggable storage implementation.
///
/// `Value` itself does not need to conform to `Sendable`. `SendableMetatype` allows the
/// node's isolated closures to use generic conformances safely.
public final class _Stored<
  Value: SendableMetatype,
  S: Storage<Value>
>: Node, Observable, CustomDebugStringConvertible {

  public let lock: NodeLock

  nonisolated(unsafe)
  private var storage: S

  private let shouldNotify: @Sendable (Value, Value) -> Bool

#if canImport(Observation)
  @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
  private var observationRegistrar: ObservationRegistrar {
    return .shared
  }
#endif

  public var potentiallyDirty: Bool {
    get {
      return false
    }
    set {
      fatalError()
    }
  }

  public let info: NodeInfo

  public var wrappedValue: Value {
    get {

#if canImport(Observation)
      if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
        observationRegistrar.access(PointerKeyPathRoot<_Stored<Value, S>>.shared, keyPath: _keyPath(self))
      }
#endif

      lock.lock()
      defer { lock.unlock() }

      // record dependency
      if let currentNode = ThreadLocal.currentNode.value {
        let edge = Edge(from: self, to: currentNode)
        outgoingEdges.append(edge)
        currentNode.incomingEdges.append(edge)
      }
      // record tracking
      if let registration = ThreadLocal.registration.value {
        self.trackingRegistrations.insert(registration)
      }

      if let transaction = ThreadLocal.transaction.value {
        switch transaction.stagedValue(for: self, as: Value.self) {
        case .absent:
          break
        case .staged(let value):
          return value
        }
      }

      return storage.value
    }
    set {
      _setGraphStoredValue(newValue)
    }
  }

  /// Sets a value while preserving `@GraphStored` property-observer semantics.
  ///
  /// Macro-generated accessors use this method to defer their observers together
  /// with a transaction's staged value. On a successful transaction, `willSet`
  /// runs once before any staged value is applied and `didSet` runs once after all
  /// staged values are applied. A failed transaction discards both callbacks.
  ///
  /// - Important: The callbacks are intentionally non-`Sendable`. Transactions
  ///   commit synchronously on the same isolation context that staged them.
  ///
  /// - Parameters:
  ///   - finalValue: The value assigned by the generated property setter.
  ///   - willSet: A callback receiving the original and final values.
  ///   - didSet: A callback receiving the original and final values.
  public func _setGraphStoredValue(
    _ finalValue: Value,
    willSet: ((Value, Value) -> Void)? = nil,
    didSet: ((Value, Value) -> Void)? = nil
  ) {
    if stageValueIfNeeded(
      finalValue,
      willSetObserver: willSet,
      didSetObserver: didSet
    ) {
      return
    }

    if let transaction = ThreadLocal.committingTransaction.value, transaction.defersMutations {
      transaction.deferUntilAfterCompletion { [self] in
        _setGraphStoredValue(finalValue, willSet: willSet, didSet: didSet)
      }
      return
    }

    if let willSet {
      lock.lock()
      let valueBeforeWillSet = storage.value
      lock.unlock()
      willSet(valueBeforeWillSet, finalValue)
    }

    let originalValue = setImmediately(finalValue)
    didSet?(originalValue, finalValue)
  }

  private func stageValueIfNeeded(
    _ finalValue: Value,
    willSetObserver: ((Value, Value) -> Void)?,
    didSetObserver: ((Value, Value) -> Void)?
  ) -> Bool {
    guard let transaction = ThreadLocal.transaction.value, transaction.isCollecting else {
      return false
    }

    lock.lock()
    defer { lock.unlock() }

    transaction.stage(
      node: self,
      initialValue: storage.value,
      finalValue: finalValue,
      willSetObserver: willSetObserver,
      didSetObserver: didSetObserver,
      shouldNotify: shouldNotify,
      readCurrentValue: { [self] in
        lock.lock()
        defer { lock.unlock() }
        return storage.value
      },
      applyValue: { [self] value in
        lock.lock()
        storage.value = value
        lock.unlock()
      },
      publishValue: { [self] _, _, publishesChange, transaction in
        publishTransactionMutation(
          publishesChange: publishesChange,
          transaction: transaction
        )
      },
      completeValue: { [self] oldValue, newValue in
        lock.lock()
        let handler = didSetHandler
        lock.unlock()
        handler?(oldValue, newValue)
      }
    )

    return true
  }

  @discardableResult
  private func setImmediately(_ newValue: Value) -> Value {
    lock.lock()

    let oldValue = storage.value

    // Skip graph and Observation notification if the value has not changed.
    guard shouldNotify(oldValue, newValue) else {
      storage.value = newValue
      let handler = didSetHandler
      lock.unlock()
      handler?(oldValue, newValue)
      return oldValue
    }

#if canImport(Observation)
    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
      withMainActor { [observationRegistrar, keyPath = _keyPath(self)] in
        observationRegistrar.willSet(
          PointerKeyPathRoot<_Stored<Value, S>>.shared,
          keyPath: keyPath
        )
      }
    }
#endif

    storage.value = newValue

    let currentOutgoingEdges = outgoingEdges
    let currentTrackingRegistrations = trackingRegistrations
    let handler = didSetHandler
    trackingRegistrations.removeAll()

    lock.unlock()

    for registration in currentTrackingRegistrations {
      registration.perform()
    }

    for edge in currentOutgoingEdges {
      edge.isPending = true
      edge.to?.potentiallyDirty = true
    }

    handler?(oldValue, newValue)

#if canImport(Observation)
    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
      withMainActor { [observationRegistrar, keyPath = _keyPath(self)] in
        observationRegistrar.didSet(
          PointerKeyPathRoot<_Stored<Value, S>>.shared,
          keyPath: keyPath
        )
      }
    }
#endif

    return oldValue
  }

  private func publishTransactionMutation(
    publishesChange: Bool,
    transaction: GraphTransaction
  ) {
    guard publishesChange else {
      return
    }

    publishTransactionChange(into: transaction)
  }

  private func publishTransactionChange(into transaction: GraphTransaction) {

    lock.lock()
    let currentOutgoingEdges = outgoingEdges
    let currentTrackingRegistrations = trackingRegistrations
    trackingRegistrations.removeAll()
    lock.unlock()

    transaction.enqueue(currentTrackingRegistrations)

    // Dirty propagation precedes Observation callbacks so a callback that reads
    // a dependent Computed node cannot observe its stale pre-transaction cache.
    for edge in currentOutgoingEdges {
      edge.isPending = true
      edge.to?.potentiallyDirty = true
    }

    // Observation is queued until graph propagation has completed for every
    // staged node. This keeps unrelated Computed caches coherent in callbacks.
#if canImport(Observation)
    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
      transaction.enqueueObservation { [observationRegistrar, keyPath = _keyPath(self)] in
        withMainActor {
          observationRegistrar.willSet(
            PointerKeyPathRoot<_Stored<Value, S>>.shared,
            keyPath: keyPath
          )
          observationRegistrar.didSet(
            PointerKeyPathRoot<_Stored<Value, S>>.shared,
            keyPath: keyPath
          )
        }
      }
    }
#endif
  }
  
  private func notifyStorageUpdated() {
    if let transaction = ThreadLocal.committingTransaction.value, transaction.phase == .applying {
      if transaction.containsMutation(for: self) {
        // A custom Storage may synchronously report its own setter. The transaction
        // already publishes that mutation after every staged node has been applied.
        return
      }

      // A shared backend can synchronously update an alias node that is not itself
      // staged. Queue only its publication so callbacks still see the final batch.
      transaction.enqueueStoragePublication(for: self) { [weak self] transaction in
        self?.publishTransactionChange(into: transaction)
      }
      return
    }

#if canImport(Observation)
    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
      // Workaround: SwiftUI will not trigger update if we call only didSet.
      // as here is where the value already updated.
      withMainActor { [observationRegistrar, keyPath = _keyPath(self)] in   
        observationRegistrar.willSet(PointerKeyPathRoot<_Stored<Value, S>>.shared, keyPath: keyPath)
        observationRegistrar.didSet(PointerKeyPathRoot<_Stored<Value, S>>.shared, keyPath: keyPath)  
      }
    }
#endif
    
    lock.lock()

    let _outgoingEdges = outgoingEdges
    let _trackingRegistrations = trackingRegistrations
    self.trackingRegistrations.removeAll()

    lock.unlock()

    for registration in _trackingRegistrations {
      registration.perform()
    }

    for edge in _outgoingEdges {
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
    storage: consuming S,
    shouldNotify: @Sendable @escaping (Value, Value) -> Bool = { _, _ in true }
  ) {
    self.info = .init(
      name: name,
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.lock = .init()
    self.storage = storage
    self.shouldNotify = shouldNotify

    self.storage.loaded(context: .init(onStorageUpdated: { [weak self] in
      self?.notifyStorageUpdated()
    }))

#if DEBUG
    Task { [weak self] in
      guard let self else { return }
      await NodeStore.shared.register(node: self)
    }
#endif
  }
  
  deinit {
//    Log.generic.debug("Deinit StoredNode: \(self.info.name.map(String.init) ?? "noname")")
    lock.lock()
    let outgoingEdges = self.outgoingEdges
    self.outgoingEdges.removeAll()
    lock.unlock()

    for edge in outgoingEdges {
      edge.to?.removeIncomingEdge(edge)
    }

    storage.unloaded()
  }
  
  public func recomputeIfNeeded() {
    // no operation
  }
  
  public var debugDescription: String {
    lock.lock()
    let value = storage.value
    lock.unlock()

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
  ///
  /// Prefer assigning `wrappedValue`. Use this method only when the caller owns the
  /// lock ordering and intentionally does not require notifications.
  ///
  /// - Parameter mutation: A closure that receives the stored value as an `inout`
  ///   parameter.
  /// - Returns: The result returned by `mutation`.
  public borrowing func unsafeModify<Result, E>(
    _ mutation: (inout Value) throws(E) -> Result
  ) throws(E) -> Result where E : Error {
    lock.lock()
    defer { lock.unlock() }
    return try mutation(&storage.value)
  }

  /// Use `unsafeModify(_:)`; its name makes the notification and locking risks explicit.
  @available(*, deprecated, renamed: "unsafeModify")
  public borrowing func withLock<Result, E>(
    _ body: (inout Value) throws(E) -> Result
  ) throws(E) -> Result where E : Error {
    try unsafeModify(body)
  }

  /// Sets a closure to be called after the value changes via wrappedValue setter.
  /// - Parameter handler: Closure receiving (oldValue, newValue)
  /// - Note: Not called for external storage updates (e.g., UserDefaults changes)
  public func onDidSet(_ handler: @escaping (Value, Value) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    self.didSetHandler = handler
  }

}

// MARK: - Equatable convenience initializer

extension _Stored where Value: Equatable {

  /// Convenience initializer for Equatable types that automatically skips
  /// notifications when the value hasn't changed.
  public convenience init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: StaticString? = nil,
    storage: consuming S
  ) {
    self.init(file, line, column, name: name, storage: storage, shouldNotify: { $0 != $1 })
  }

}

// MARK: - AnyObject convenience initializer (for non-Equatable reference types)

extension _Stored where Value: AnyObject {

  /// Convenience initializer for reference types that automatically skips
  /// notifications when the reference identity hasn't changed.
  public convenience init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: StaticString? = nil,
    storage: consuming S
  ) {
    self.init(file, line, column, name: name, storage: storage, shouldNotify: { $0 !== $1 })
  }

}

// MARK: - Equatable & AnyObject convenience initializer (resolve ambiguity)

extension _Stored where Value: Equatable & AnyObject {

  /// Convenience initializer for Equatable reference types.
  /// Uses value equality (Equatable) rather than reference identity.
  public convenience init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: StaticString? = nil,
    storage: consuming S
  ) {
    self.init(file, line, column, name: name, storage: storage, shouldNotify: { $0 != $1 })
  }

}
