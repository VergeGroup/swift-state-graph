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

  private let shouldNotify: @Sendable (Value, Value) -> Bool

#if canImport(Observation)
  @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
  nonisolated(unsafe)
  private var observationRegistrar = NodeObservationRegistrar()

  /// Returns whether this node has allocated its Apple Observation state.
  var _isObservationRegistrarInitialized: Bool {
    lock.lock()
    defer { lock.unlock() }
    return observationRegistrar.isInitialized
  }
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
      lock.lock()
      defer { lock.unlock() }

#if canImport(Observation)
      if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
        let observationRegistrar = observationRegistrar.initializeIfNeeded()
        observationRegistrar.access(
          PointerKeyPathRoot<Stored<Value>>.shared,
          keyPath: _keyPath(self)
        )
      }
#endif

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
    set {
      lock.lock()

      let oldValue = value

      guard shouldNotify(oldValue, newValue) else {
        value = newValue
        let didSetHandler = self.didSetHandler
        lock.unlock()
        didSetHandler?(oldValue, newValue)
        return
      }

#if canImport(Observation)
      let observationRegistrar = observationRegistrar.current

      if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
        if let observationRegistrar {
          withMainActor { [observationRegistrar, keyPath = _keyPath(self)] in
            observationRegistrar.willSet(
              PointerKeyPathRoot<Stored<Value>>.shared,
              keyPath: keyPath
            )
          }
        }
      }

      defer {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
          if let observationRegistrar {
            withMainActor { [observationRegistrar, keyPath = _keyPath(self)] in
              observationRegistrar.didSet(
                PointerKeyPathRoot<Stored<Value>>.shared,
                keyPath: keyPath
              )
            }
          }
        }
      }
#endif

      value = newValue

      let outgoingEdges = self.outgoingEdges
      let trackingRegistrations = self.trackingRegistrations
      let didSetHandler = self.didSetHandler
      self.trackingRegistrations.removeAll()

      lock.unlock()

      Self.publishGraphUpdates(
        trackingRegistrations: trackingRegistrations,
        outgoingEdges: outgoingEdges
      )

      didSetHandler?(oldValue, newValue)
    }
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
    lock.lock()
    let value = self.value
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
  public borrowing func unsafeModify<Result, E>(
    _ mutation: (inout Value) throws(E) -> Result
  ) throws(E) -> Result where E: Error {
    lock.lock()
    defer { lock.unlock() }
    return try mutation(&value)
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
