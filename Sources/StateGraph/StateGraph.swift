import os.lock

#if canImport(Observation)
  import Observation
#endif

/**
 based on
 https://talk.objc.io/episodes/S01E429-attribute-graph-part-1
 */

private enum TaskLocals {
  @TaskLocal
  static var currentNode: (any Node)?
}

protocol Node: AnyObject, Sendable {
  var name: String? { get }

  /// edges affecting nodes
  var outgoingEdges: ContiguousArray<Edge> { get set }

  /// inverse edges that depending on nodes
  var incomingEdges: ContiguousArray<Edge> { get set }

  ///
  var stateViews: ContiguousArray<Weak<StateView>> { get set }

  var potentiallyDirty: Bool { get set }

  func recomputeIfNeeded()
}

extension Node {
  func register(_ value: StateView) {
    let box = Weak(value)
    guard stateViews.contains(box) == false else {
      return 
    }
    stateViews.append(box)
  }

}

struct Weak<T: AnyObject>: Equatable {

  public static func == (lhs: Weak<T>, rhs: Weak<T>) -> Bool {
    return lhs.value === rhs.value
  }

  weak var value: T?

  init(_ value: T) {
    self.value = value
  }
}

extension Weak: Sendable where T: Sendable {}

/// A node that functions as an endpoint in a Directed Acyclic Graph (DAG).
///
/// `StoredNode` can have its value set directly from the outside, and changes to its value
/// automatically propagate to dependent nodes. This node doesn't perform any computations
/// and serves purely as a value container.
///
/// - When value changes: Changes propagate to all dependent nodes, triggering recalculations
/// - When value is accessed: Dependencies are recorded, automatically building the graph structure
///
/// Example usage:
/// ```swift
/// let graph = StateGraph()
/// let inputNode = graph.input(name: "input", 10)
/// ```
public final class StoredNode<Value>: Node, Observable {

  private let lock: OSAllocatedUnfairLock<Void>

  nonisolated(unsafe)
    private var _value: Value

  #if canImport(Observation)
    nonisolated(unsafe)
      private var observationRegistrar: ObservationRegistrar?
  #endif

  public var potentiallyDirty: Bool {
    get {
      return false
    }
    set {
      fatalError()
    }
  }

  public let name: String?

  public var wrappedValue: Value {
    _read {
      lock.lock()
      defer { lock.unlock() }
      #if canImport(Observation)
        synchronized_prepareObservationRegistrar()
        observationRegistrar!.access(self, keyPath: \.self)
      #endif
      // record dependency
      if let c = TaskLocals.currentNode {
        let edge = Edge(from: self, to: c)
        outgoingEdges.append(edge)
        c.incomingEdges.append(edge)
      }
      yield _value
    }
    _modify {

      lock.lock()

      do {
        #if canImport(Observation)
          synchronized_prepareObservationRegistrar()
          observationRegistrar!.willSet(self, keyPath: \.self)

          defer {
            observationRegistrar!.didSet(self, keyPath: \.self)
          }
        #endif

        yield &_value

        for e in outgoingEdges {
          e.isPending = true
          e.to.potentiallyDirty = true
        }
        stateViews.compactForEach {
          $0.didMemberChanged()
        }
        _sink.send()
      }

      lock.unlock()
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
    var outgoingEdges: ContiguousArray<Edge> = []

  nonisolated(unsafe)
    var stateViews: ContiguousArray<Weak<StateView>> = []

  public init(
    name: String? = nil,
    wrappedValue: Value
  ) {
    self.name = name
    self.lock = .init()
    self._value = wrappedValue
  }

  deinit {
    Log.generic.debug("Deinit Stored: \(self.name ?? "noname")")
    for e in outgoingEdges {
      e.to.incomingEdges.removeAll(where: { $0 === e })
    }
  }

  public func recomputeIfNeeded() {
    // no operation
  }

  @inline(__always)
  private func synchronized_prepareObservationRegistrar() {
    if observationRegistrar == nil {
      observationRegistrar = .init()
    }
  }

  nonisolated(unsafe)
    private var _sink: Sink = .init()

  public func onChange() -> AsyncStream<Void> {
    lock.lock()
    defer { lock.unlock() }
    return _sink.addStream()
  }

}

/// A node that computes its value based on other nodes in a Directed Acyclic Graph (DAG).
///
/// `ComputedNode` derives its value from other nodes through a computation rule.
/// When any of its dependencies change, the node becomes dirty and will recalculate
/// its value on the next access. This node caches its computed value for performance.
///
/// - Value is lazily computed: Calculations only occur when the value is accessed
/// - Dependencies are tracked: The node automatically tracks which nodes it depends on
/// - Changes propagate: When this node's value changes, downstream nodes are notified
///
/// Example usage:
/// ```swift
/// let graph = StateGraph()
/// let a = graph.input(name: "A", 10)
/// let b = graph.input(name: "B", 20)
/// let c = graph.rule(name: "C") { _ in a.wrappedValue + b.wrappedValue }
/// ```
public final class ComputedNode<Value>: Node, Observable {

  private let lock: OSAllocatedUnfairLock<Void>

  nonisolated(unsafe)
    private var _cachedValue: Value?

  #if canImport(Observation)
    nonisolated(unsafe)
      private var observationRegistrar: ObservationRegistrar?
  #endif

  public var potentiallyDirty: Bool {
    get {
      lock.lock()
      defer {
        lock.unlock()
      }
      return _potentiallyDirty
    }
    set {
      lock.lock()
      defer {
        lock.unlock()
      }
      _potentiallyDirty = newValue
    }
  }

  nonisolated(unsafe)
    private var _potentiallyDirty: Bool = false
  {
    didSet {

      guard _potentiallyDirty, _potentiallyDirty != oldValue else { return }

      #if canImport(Observation)
        prepareObservationRegistrar()
        observationRegistrar!.willSet(self, keyPath: \.self)
      #endif

      for e in outgoingEdges {
        e.to.potentiallyDirty = true
      }

      stateViews.compactForEach {
        $0.didMemberChanged()
      }

      _sink.send()
    }
  }

  public let name: String?

  public var wrappedValue: Value {
    _read {
      #if canImport(Observation)
        prepareObservationRegistrar()
        observationRegistrar!.access(self, keyPath: \.self)
      #endif
      recomputeIfNeeded()
      yield _cachedValue!
    }
  }

  let rule: @Sendable () -> Value

  nonisolated(unsafe)
    var incomingEdges: ContiguousArray<Edge> = []
  nonisolated(unsafe)
    var outgoingEdges: ContiguousArray<Edge> = []
  nonisolated(unsafe)
    var stateViews: ContiguousArray<Weak<StateView>> = []

  public init(
    name: String? = nil,
    rule: @escaping @Sendable () -> Value
  ) {
    self.name = name
    self.rule = rule
    self.lock = .init()
  }

  deinit {
    Log.generic.debug("Deinit Computed: \(self.name ?? "noname")")
    for e in incomingEdges {
      e.from.outgoingEdges.removeAll(where: { $0 === e })
    }
  }

  public func recomputeIfNeeded() {

    lock.lock()
    defer { lock.unlock() }

    // record dependency
    if let c = TaskLocals.currentNode {
      let edge = Edge(from: self, to: c)
      outgoingEdges.append(edge)
      c.incomingEdges.append(edge)
    }

    if !_potentiallyDirty && _cachedValue != nil { return }

    for edge in incomingEdges {
      edge.from.recomputeIfNeeded()
    }

    let hasPendingIncomingEdge = incomingEdges.contains(where: \.isPending)

    if hasPendingIncomingEdge || _cachedValue == nil {

      TaskLocals.$currentNode.withValue(self) {
        let isInitial = _cachedValue == nil
        removeIncomingEdges()
        _cachedValue = rule()
        // TODO only if _cachedValue has changed
        if !isInitial {
          for o in outgoingEdges {
            o.isPending = true
          }
        }
      }

    }

    _potentiallyDirty = false

  }

  private func removeIncomingEdges() {
    for e in incomingEdges {
      e.from.outgoingEdges.removeAll(where: { $0 === e })
    }
    incomingEdges.removeAll()
  }

  @inline(__always)
  private func prepareObservationRegistrar() {
    if observationRegistrar == nil {
      observationRegistrar = .init()
    }
  }

  nonisolated(unsafe)
    private var _sink: Sink = .init()

  public func onChange() -> AsyncStream<Void> {
    lock.lock()
    defer {
      lock.unlock()
    }
    return _sink.addStream()
  }
}

@DebugDescription
public final class Edge: CustomDebugStringConvertible {

  unowned let from: any Node
  unowned let to: any Node

  var isPending: Bool = false

  init(from: any Node, to: any Node) {
    self.from = from
    self.to = to
  }

  public var debugDescription: String {
    "\(from.name) -> \(to.name)"
  }

  deinit {
    Log.generic.debug("Deinit Edge")
  }

}

extension ContiguousArray<Weak<StateView>> {

  mutating func compactForEach(_ body: (StateView) -> Void) {

    self.removeAll {
      if let value = $0.value {
        body(value)
        return false
      } else {
        return true
      }
    }

  }
}
