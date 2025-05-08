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
  static var currentNode: (any TypeErasedNode)?
}

protocol TypeErasedNode: Hashable, AnyObject, Sendable, CustomDebugStringConvertible {
  var name: String? { get }

  /// edges affecting nodes
  var outgoingEdges: ContiguousArray<Edge> { get set }

  /// inverse edges that depending on nodes
  var incomingEdges: ContiguousArray<Edge> { get set }

  var trackingRegistrations: Set<TrackingRegistration> { get set }

  var potentiallyDirty: Bool { get set }

  func recomputeIfNeeded()
}

protocol Node: TypeErasedNode {
  
  associatedtype Value
  
  var wrappedValue: Value { get }
  
}

extension Node {
  // MARK: Equatable
  public static func == (lhs: Self, rhs: Self) -> Bool {
    return lhs === rhs
  }
  
  // MARK: Hashable
  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
  
  public func ifChanged(
    _ body: @escaping (Self.Value) -> Void,
    isolation: isolated (any Actor)? = #isolation
  ) where Value : Equatable {
    
    let _body = UnsafeSendable(body)
        
    let currentValue = UnsafeSendable(self.wrappedValue)
    
    withStateGraphTracking { 
      _ = self.wrappedValue
    } didChange: { [weak self] in
      Task {
        // implicit capture
        // https://forums.swift.org/t/closure-isolation-control/70378/48
        let _ = isolation
        await perform({
          guard let self = self else { 
            return 
          }
          let newValue = self.wrappedValue
          guard newValue != currentValue._value else {
            return 
          }
          _body._value(newValue)
        }, isolation: isolation)
      }
    }
    
  }
}

import Combine
import os.lock

extension Node {
  
  public func observe() -> AsyncStartWithSequence<AsyncMapSequence<AsyncStream<Void>, Self.Value>> {
        
   let stream = withStateGraphTrackingStream {
      _ = self.wrappedValue
    }
    .map { 
      self.wrappedValue
    }
    .startWith(self.wrappedValue)
             
    return stream
  }
  
}

extension AsyncSequence {
  func startWith(_ value: Element) -> AsyncStartWithSequence<Self> {
    return AsyncStartWithSequence(self, startWith: value)
  }
}

public struct AsyncStartWithSequence<Base: AsyncSequence>: AsyncSequence {
  
  public struct AsyncIterator: AsyncIteratorProtocol {
    public typealias Element = Base.Element
    
    private var base: Base.AsyncIterator
    private var first: Base.Element?

    init(_ value: Base.AsyncIterator, startWith: Base.Element) {
      self.base = value
      self.first = startWith
    }
    
    public mutating func next() async throws -> Base.Element? {
      if let first = first {
        self.first = nil
        return first
      }
      return try await base.next()
    }
  }
  
  public typealias Element = Base.Element
  
  let base: Base
  let startWith: Base.Element

  init(_ base: Base, startWith: Base.Element) {
    self.base = base
    self.startWith = startWith
  }
  
  public func makeAsyncIterator() -> AsyncIterator {
    return AsyncIterator(base.makeAsyncIterator(), startWith: startWith)
  }
}

extension AsyncStartWithSequence: Sendable where Base.Element: Sendable, Base: Sendable {}

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
public final class StoredNode<Value>: Node, Observable, CustomDebugStringConvertible {

  private let lock: OSAllocatedUnfairLock<Void>

  nonisolated(unsafe)
    private var _value: Value

  #if canImport(Observation)
    nonisolated(unsafe)
  private var observationRegistrar: ObservationRegistrar = .init()
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
      
#if canImport(Observation)
      observationRegistrar.access(self, keyPath: \.self)
#endif
      
      lock.lock()
      defer { lock.unlock() }
                
      // record dependency
      if let c = TaskLocals.currentNode {
        let edge = Edge(from: self, to: c)
        outgoingEdges.append(edge)
        c.incomingEdges.append(edge)
      }
      // record tracking
      if let registration = TrackingRegistration.registration {
        self.trackingRegistrations.insert(registration)
      }
      yield _value
    }
    _modify {

#if canImport(Observation)
      observationRegistrar.willSet(self, keyPath: \.self)
      
      defer {
        observationRegistrar.didSet(self, keyPath: \.self)
      }
#endif
      
      lock.lock()

      yield &_value
      
      for e in outgoingEdges {
        e.isPending = true
        e.to.potentiallyDirty = true
      }
      
      let _trackingRegistrations = trackingRegistrations
      self.trackingRegistrations.removeAll()
                           
      lock.unlock()
      
      for r in _trackingRegistrations {
        r.perform()
      }
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
  var trackingRegistrations: Set<TrackingRegistration> = []

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
    
    #if DEBUG
    Task {
      await NodeStore.shared.register(node: self)
    }
    #endif
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

  public var debugDescription: String {
    "StoredNode<\(Value.self)>(\(String(describing: _value)))"
  }
}

/*
public protocol ComputedNodeDescriptor {
  
  associatedtype Value
  
  func compute(context: inout ComputedNode<Value>.Context) -> Value
}

public struct AnyComputedNodeDescriptor<Value>: ComputedNodeDescriptor {
  
  private let computeClosure: (inout ComputedNode<Value>.Context) -> Value
  
  public init(compute: @escaping (inout ComputedNode<Value>.Context) -> Value) {
    self.computeClosure = compute  
  }
    
  public func compute(context: inout ComputedNode<Value>.Context) -> Value {
    computeClosure(&context)
  }
  
}
*/

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
public final class ComputedNode<Value>: Node, Observable, CustomDebugStringConvertible {
  
  public struct Context {
    
  }
    
  private let lock: OSAllocatedUnfairLock<Void>

  nonisolated(unsafe)
    private var _cachedValue: Value?

  private let comparator: @Sendable (Value, Value) -> Bool
  
  #if canImport(Observation)
    nonisolated(unsafe)
  private var observationRegistrar: ObservationRegistrar = .init()
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
        observationRegistrar.willSet(self, keyPath: \.self)
      #endif

      for e in outgoingEdges {
        e.to.potentiallyDirty = true
      }

      for r in trackingRegistrations {
        r.perform()
      }
      trackingRegistrations.removeAll()
    }
  }

  public let name: String?
  private let sourceLocation: SourceLocation

  public var wrappedValue: Value {
    _read {
      #if canImport(Observation)
        observationRegistrar.access(self, keyPath: \.self)
      #endif
      recomputeIfNeeded()
      yield _cachedValue!
    }
  }

  private let rule: @Sendable (inout Context) -> Value

  nonisolated(unsafe)
    var incomingEdges: ContiguousArray<Edge> = []
  nonisolated(unsafe)
    var outgoingEdges: ContiguousArray<Edge> = []
  nonisolated(unsafe)
  var trackingRegistrations: Set<TrackingRegistration> = []

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
    rule: @escaping @Sendable (inout Context) -> Value
  ) {
    self.sourceLocation = .init(file: file, line: line, column: column)
    self.name = name
    self.rule = rule
    self.lock = .init()
    self.comparator = { _, _ in false }
    
#if DEBUG
    Task {
      await NodeStore.shared.register(node: self)
    }
#endif
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
    rule: @escaping @Sendable (inout Context) -> Value
  ) where Value: Equatable {
    self.sourceLocation = .init(file: file, line: line, column: column)
    self.name = name
    self.rule = rule
    self.lock = .init()
    self.comparator = { $0 == $1 }
        
#if DEBUG
    Task {
      await NodeStore.shared.register(node: self)
    }
#endif
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
      // TODO: consider removing duplicated edges
      outgoingEdges.append(edge)
      c.incomingEdges.append(edge)
    }
    // record tracking
    if let registration = TrackingRegistration.registration {
      self.trackingRegistrations.insert(registration)
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
        var context = Context()
        _cachedValue = rule(&context)

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
   
  public var debugDescription: String {
    "ComputedNode<\(Value.self)>(\(String(describing: _cachedValue)))"
  }
  
}

@DebugDescription
public final class Edge: CustomDebugStringConvertible {

  unowned let from: any TypeErasedNode
  unowned let to: any TypeErasedNode

  var isPending: Bool = false

  init(from: any TypeErasedNode, to: any TypeErasedNode) {
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
