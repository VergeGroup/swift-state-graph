import Foundation

#if canImport(Observation)
  import Observation
#endif

// MARK: - Storage Protocol

/// Collects synchronous storage callbacks until the source node releases its lock.
///
/// Instances are thread-confined by `ThreadLocal.deferredStorageUpdates` and must
/// be drained by the same thread that created them.
final class DeferredStorageUpdates {

  private var updates: [@Sendable () -> Void] = []

  func append(_ update: @escaping @Sendable () -> Void) {
    updates.append(update)
  }

  func perform() {
    let updates = self.updates
    self.updates.removeAll()

    for update in updates {
      update()
    }
  }
}

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
    if let deferredUpdates = ThreadLocal.deferredStorageUpdates.value {
      deferredUpdates.append(onStorageUpdated)
    } else {
      onStorageUpdated()
    }
  }
  
}

// MARK: - Concrete Storage Implementations

/// Serializes UserDefaults access and defers graph publication from synchronous write notifications.
private final class UserDefaultsStorageCoordinator: Sendable {

  private final class AccessContext {
    var publications: [@Sendable () -> Void] = []
  }

  static let shared = UserDefaultsStorageCoordinator()

  private let lock = NSRecursiveLock()
  private let accessContextKey = "org.vergegroup.state-graph.user-defaults-access-context"

  func withAccess<Result>(_ body: () -> Result) -> Result {
    if currentAccessContext != nil {
      lock.lock()
      defer { lock.unlock() }
      return body()
    }

    let context = AccessContext()
    Thread.current.threadDictionary[accessContextKey] = context

    lock.lock()
    let result = body()
    lock.unlock()

    Thread.current.threadDictionary.removeObject(forKey: accessContextKey)

    for publication in context.publications {
      publication()
    }

    return result
  }

  func withWrite<Result>(_ body: () -> Result) -> Result {
    withAccess(body)
  }

  func publish(_ publication: @escaping @Sendable () -> Void) {
    guard let context = currentAccessContext else {
      publication()
      return
    }

    context.publications.append(publication)
  }

  private var currentAccessContext: AccessContext? {
    Thread.current.threadDictionary[accessContextKey] as? AccessContext
  }
}

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

  private enum Snapshot: Sendable {
    case missing
    case value(Value)
  }

  /// Sendable ownership wrapper for Foundation's opaque observer token.
  private final class ObserverToken: @unchecked Sendable {
    let value: NSObjectProtocol

    init(_ value: NSObjectProtocol) {
      self.value = value
    }
  }

  private struct State: Sendable {
    var cachedValue: Snapshot = .missing
    var previousValue: Snapshot = .missing
    var subscription: ObserverToken?
    var isLoaded = false
    var lifecycleGeneration: UInt64 = 0
  }

  nonisolated(unsafe)
  private let userDefaults: UserDefaults
  private let key: String
  private let defaultValue: Value

  private let state = OSAllocatedUnfairLock(initialState: State())

  public var value: Value {
    get {
      UserDefaultsStorageCoordinator.shared.withAccess {
        if case .value(let cachedValue) = state.withLock({ $0.cachedValue }) {
          return cachedValue
        }

        let loadedValue = Value._getValue(
          from: userDefaults,
          forKey: key,
          defaultValue: defaultValue
        )

        return state.withLock { state in
          if case .value(let cachedValue) = state.cachedValue {
            return cachedValue
          }

          state.cachedValue = .value(loadedValue)
          return loadedValue
        }
      }
    }
    set {
      UserDefaultsStorageCoordinator.shared.withWrite {
        state.withLock { state in
          state.cachedValue = .value(newValue)
          state.previousValue = .value(newValue)
        }

        newValue._setValue(to: userDefaults, forKey: key)
      }
    }
  }

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
    let generation = state.withLock { state -> UInt64? in
      guard !state.isLoaded else { return nil }

      state.isLoaded = true
      state.lifecycleGeneration &+= 1
      state.cachedValue = .missing
      state.previousValue = .missing
      return state.lifecycleGeneration
    }

    guard let generation else { return }

    let subscription = ObserverToken(
      NotificationCenter.default
      .addObserver(
        forName: UserDefaults.didChangeNotification,
        object: userDefaults,
        queue: nil,
        using: { [weak self] _ in
          guard let self else { return }
          self.userDefaultsDidChange(context: context, generation: generation)
        }
      )
    )

    let didStoreSubscription = state.withLock { state in
      guard
        state.isLoaded,
        state.lifecycleGeneration == generation,
        state.subscription == nil
      else {
        return false
      }

      state.subscription = subscription
      return true
    }

    if !didStoreSubscription {
      NotificationCenter.default.removeObserver(subscription.value)
      return
    }

    let initialValue = value
    state.withLock { state in
      guard state.isLoaded, state.lifecycleGeneration == generation else {
        return
      }

      if case .missing = state.previousValue {
        state.previousValue = .value(initialValue)
      }
    }
  }

  public func unloaded() {
    let subscription = state.withLock { state in
      state.isLoaded = false
      state.lifecycleGeneration &+= 1

      let subscription = state.subscription
      state.subscription = nil
      return subscription
    }

    if let subscription {
      NotificationCenter.default.removeObserver(subscription.value)
    }
  }

  private func userDefaultsDidChange(
    context: StorageContext,
    generation: UInt64
  ) {
    guard state.withLock({ state in
      state.isLoaded && state.lifecycleGeneration == generation
    }) else {
      return
    }

    let shouldNotify = UserDefaultsStorageCoordinator.shared.withAccess {
      let loadedValue = Value._getValue(
        from: userDefaults,
        forKey: key,
        defaultValue: defaultValue
      )

      return state.withLock { state in
        guard state.isLoaded, state.lifecycleGeneration == generation else {
          return false
        }

        let didChange: Bool
        switch state.previousValue {
        case .missing:
          didChange = true
        case .value(let previousValue):
          didChange = previousValue != loadedValue
        }

        state.cachedValue = .value(loadedValue)
        state.previousValue = .value(loadedValue)
        return didChange
      }
    }

    if shouldNotify {
      UserDefaultsStorageCoordinator.shared.publish {
        context.notifyStorageUpdated()
      }
    }
  }
}

// MARK: - Base Stored Node

public final class _Stored<Value, S: Storage<Value>>: Node, Observable, CustomDebugStringConvertible {

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

      return storage.value
    }
    set {
      lock.lock()

      let oldValue = storage.value

      // Skip notification if value hasn't changed (like Observation.framework)
      guard shouldNotify(oldValue, newValue) else {
        let deferredStorageUpdates = assignStorageValue(newValue)
        let _didSetHandler = didSetHandler
        lock.unlock()
        deferredStorageUpdates?.perform()
        _didSetHandler?(oldValue, newValue)
        return
      }

#if canImport(Observation)
      if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
        withMainActor { [observationRegistrar, keyPath = _keyPath(self)] in
          observationRegistrar.willSet(PointerKeyPathRoot<_Stored<Value, S>>.shared, keyPath: keyPath)
        }
      }

      defer {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
          withMainActor { [observationRegistrar, keyPath = _keyPath(self)] in
            observationRegistrar.didSet(PointerKeyPathRoot<_Stored<Value, S>>.shared, keyPath: keyPath)
          }
        }
      }
#endif

      let deferredStorageUpdates = assignStorageValue(newValue)

      let _outgoingEdges = outgoingEdges
      let _trackingRegistrations = trackingRegistrations
      let _didSetHandler = didSetHandler
      self.trackingRegistrations.removeAll()

      lock.unlock()

      deferredStorageUpdates?.perform()

      for registration in _trackingRegistrations {
        registration.perform()
      }

      for edge in _outgoingEdges {
        edge.isPending = true
        edge.to.potentiallyDirty = true
      }

      _didSetHandler?(oldValue, newValue)
    }
  }

  private func assignStorageValue(_ newValue: Value) -> DeferredStorageUpdates? {
    guard ThreadLocal.deferredStorageUpdates.value == nil else {
      storage.value = newValue
      return nil
    }

    let deferredUpdates = DeferredStorageUpdates()
    ThreadLocal.deferredStorageUpdates.withValue(deferredUpdates) {
      storage.value = newValue
    }
    return deferredUpdates
  }
  
  private func notifyStorageUpdated() {
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
      edge.to.potentiallyDirty = true
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
    Task {
      await NodeStore.shared.register(node: self)
    }
#endif
  }
  
  deinit {
//    Log.generic.debug("Deinit StoredNode: \(self.info.name.map(String.init) ?? "noname")")
    for edge in outgoingEdges {
      edge.to.incomingEdges.removeAll(where: { $0 === edge })
    }
    outgoingEdges.removeAll()
    storage.unloaded()
  }
  
  public func recomputeIfNeeded() {
    // no operation
  }
  
  public var debugDescription: String {
    let value = storage.value
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
