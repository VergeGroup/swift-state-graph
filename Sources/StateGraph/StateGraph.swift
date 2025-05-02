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
  static var currentNode: (any NodeType)?
}

protocol NodeType: Hashable, AnyObject, Sendable, CustomDebugStringConvertible {
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

extension NodeType {
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
/// ```
public final class StoredNode<Value>: NodeType, Observable, CustomDebugStringConvertible {

  // MARK: Equatable
  public static func == (lhs: StoredNode<Value>, rhs: StoredNode<Value>) -> Bool {
    return lhs === rhs
  }

  // MARK: Hashable
  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }

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
  let sourceLocation: SourceLocation

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
          $0._onMemberChange()
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
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: String? = nil,
    wrappedValue: Value
  ) {
    self.sourceLocation = .init(file: file, line: line, column: column)
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

  public var debugDescription: String {
    "StoredNode<\(Value.self)>(\(String(describing: _value)))"
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
/// ```
public final class ComputedNode<Value>: NodeType, Observable, CustomDebugStringConvertible {
    
  // MARK: Equatable
  public static func == (lhs: ComputedNode<Value>, rhs: ComputedNode<Value>) -> Bool {
    return lhs === rhs
  }

  // MARK: Hashable
  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }

  private let lock: OSAllocatedUnfairLock<Void>

  nonisolated(unsafe)
    private var _cachedValue: Value?

  private let comparator: @Sendable (Value, Value) -> Bool

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
        $0._onMemberChange()
      }

      _sink.send()
    }
  }

  public let name: String?
  private let sourceLocation: SourceLocation

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

  private let rule: @Sendable () -> Value

  nonisolated(unsafe)
    var incomingEdges: ContiguousArray<Edge> = []
  nonisolated(unsafe)
    var outgoingEdges: ContiguousArray<Edge> = []
  nonisolated(unsafe)
    var stateViews: ContiguousArray<Weak<StateView>> = []

  /// Initializes a computed node.
  ///
  /// This initializer uses a comparison function that always returns `false`.
  /// This means updates will always occur regardless of whether the value has changed.
  ///
  /// - Parameters:
  ///   - file: The file where the node is created (defaults to current file)
  ///   - line: The line number where the node is created (defaults to current line)
  ///   - column: The column number where the node is created (defaults to current column)
  ///   - name: Optional name for the node
  ///   - rule: The rule that computes the node's value
  public init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: String? = nil,
    rule: @escaping @Sendable () -> Value
  ) {
    self.sourceLocation = .init(file: file, line: line, column: column)
    self.name = name
    self.rule = rule
    self.lock = .init()
    self.comparator = { _, _ in false }
  }

  /// Initializes a computed node.
  ///
  /// This initializer is used for value types that conform to `Equatable`,
  /// using the `==` operator to compare values for equality.
  /// Updates will only occur when the value has changed.
  ///
  /// - Parameters:
  ///   - file: The file where the node is created (defaults to current file)
  ///   - line: The line number where the node is created (defaults to current line)
  ///   - column: The column number where the node is created (defaults to current column)
  ///   - name: Optional name for the node
  ///   - rule: The rule that computes the node's value
  public init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: String? = nil,
    rule: @escaping @Sendable () -> Value
  ) where Value: Equatable {
    self.sourceLocation = .init(file: file, line: line, column: column)
    self.name = name
    self.rule = rule
    self.lock = .init()
    self.comparator = { $0 == $1 }
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

      TaskLocals.$currentNode.withValue(self) { () -> Void in
        let previousValue = _cachedValue
        removeIncomingEdges()
        _cachedValue = rule()

        // propagate changes to dependent nodes
        do {

          if let previousValue = previousValue,
             comparator(
              previousValue,
              _cachedValue!
             ) == false 
          {
            for o in outgoingEdges {
              o.isPending = true
            }
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
  
  public var debugDescription: String {
    "ComputedNode<\(Value.self)>(\(String(describing: _cachedValue)))"
  }
  
}

@DebugDescription
public final class Edge: CustomDebugStringConvertible {

  unowned let from: any NodeType
  unowned let to: any NodeType

  var isPending: Bool = false

  init(from: any NodeType, to: any NodeType) {
    self.from = from
    self.to = to
  }

  public var debugDescription: String {
    "\(from.debugDescription) -> \(to.name.debugDescription)"
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
