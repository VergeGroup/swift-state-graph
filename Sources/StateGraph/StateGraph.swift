import Observation

/**
 based on
 https://talk.objc.io/episodes/S01E429-attribute-graph-part-1
 */
public final class StateGraph {
  
  /// for dependecy capturing
  fileprivate unowned var currentNode: (any Node)?
      
  public init() {}
  
  public func input<Value>(
    name: String,
    _ value: Value
  ) -> StoredNode<Value> {
    let n = StoredNode(name: name, in: self, wrappedValue: value)
    return n
  }

  public func rule<Value>(
    name: String,
    _ rule: @escaping (StateGraph) -> Value
  ) -> ComputedNode<Value> {
    let n = ComputedNode(name: name, in: self, rule: rule)
    return n
  }
      
}

public protocol Node: AnyObject {
  var name: String { get }
  
  /// edges affecting nodes
  var outgoingEdges: ContiguousArray<Edge> { get set }
  
  /// inverse edges that depending on nodes
  var incomingEdges: ContiguousArray<Edge> { get set }
  
  ///
  var stateViews: ContiguousArray<StateView> { get set }
  
  var potentiallyDirty: Bool { get set }
  
  func recomputeIfNeeded()  
}

/**
 * A node that functions as an endpoint in a Directed Acyclic Graph (DAG).
 *
 * `StoredNode` can have its value set directly from the outside, and changes to its value 
 * automatically propagate to dependent nodes. This node doesn't perform any computations 
 * and serves purely as a value container.
 *
 * - When value changes: Changes propagate to all dependent nodes, triggering recalculations
 * - When value is accessed: Dependencies are recorded, automatically building the graph structure
 *
 * Example usage:
 * ```swift
 * let graph = StateGraph()
 * let inputNode = graph.input(name: "input", 10)
 * ```
 */
public final class StoredNode<Value>: Node, Observable {
  
  unowned let graph: StateGraph
  private var value: Value
  
#if canImport(Observation)
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
  
  public let name: String
  
  public var wrappedValue: Value {
    _read {
#if canImport(Observation)
      prepareObservationRegistrar()
      observationRegistrar!.access(self, keyPath: \.self)
#endif
      // record dependency
      if let c = graph.currentNode {
        let edge = Edge(from: self, to: c)
        outgoingEdges.append(edge)
        c.incomingEdges.append(edge)
      }
      yield value
    }
    _modify {

#if canImport(Observation)   
      prepareObservationRegistrar()
      observationRegistrar!.willSet(self, keyPath: \.self)
      
      defer {
        observationRegistrar!.didSet(self, keyPath: \.self)
      }
#endif
      
      yield &value
      
      propagateDirty()    
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
  
  public var outgoingEdges: ContiguousArray<Edge> = []
  public var stateViews: ContiguousArray<StateView> = []
  
  init(
    name: String,
    in graph: StateGraph,
    wrappedValue: Value
  ) {
    self.name = name
    self.graph = graph
    self.value = wrappedValue
  }
  
  private func propagateDirty() {
    for e in outgoingEdges {
      e.isPending = true
      e.to.potentiallyDirty = true
    }
    _sink.send()
  }
  
  public func recomputeIfNeeded() {
    // no operation
  }
  
  @inline(__always)
  private func prepareObservationRegistrar() {
    if observationRegistrar == nil {
      observationRegistrar = .init()
    }
  }
  
  deinit {    
    Log.generic.debug("Deinit Stored: \(self.name)")
  }
      
  private var _sink: Sink = .init()
  
  public func onChange() -> AsyncStream<Void> {
    _sink.addStream()
  }
  
}

/**
 * A node that computes its value based on other nodes in a Directed Acyclic Graph (DAG).
 *
 * `ComputedNode` derives its value from other nodes through a computation rule.
 * When any of its dependencies change, the node becomes dirty and will recalculate 
 * its value on the next access. This node caches its computed value for performance.
 *
 * - Value is lazily computed: Calculations only occur when the value is accessed
 * - Dependencies are tracked: The node automatically tracks which nodes it depends on
 * - Changes propagate: When this node's value changes, downstream nodes are notified
 *
 * Example usage:
 * ```swift
 * let graph = StateGraph()
 * let a = graph.input(name: "A", 10)
 * let b = graph.input(name: "B", 20)
 * let c = graph.rule(name: "C") { _ in a.wrappedValue + b.wrappedValue }
 * ```
 */
public final class ComputedNode<Value>: Node, Observable {
  
  unowned let graph: StateGraph
  private var _cachedValue: Value?
  
#if canImport(Observation)
  private var observationRegistrar: ObservationRegistrar?
#endif
  
  public var potentiallyDirty: Bool = false {
    didSet {
            
      guard potentiallyDirty, potentiallyDirty != oldValue else { return }
      
#if canImport(Observation)
      prepareObservationRegistrar()
      observationRegistrar!.willSet(self, keyPath: \.self)
#endif
      
      for e in outgoingEdges {
        e.to.potentiallyDirty = true
      }
      
      for owner in stateViews {
        owner.didMemberChanged()
      }
      
      _sink.send()
    }
  }
  
  public let name: String
  
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
    
  let rule: ((StateGraph) -> Value)
  public var incomingEdges: ContiguousArray<Edge> = []
  public var outgoingEdges: ContiguousArray<Edge> = []
  public var stateViews: ContiguousArray<StateView> = []
     
  init(
    name: String,
    in graph: StateGraph,
    rule: @escaping (StateGraph) -> Value
  ) {
    self.name = name
    self.graph = graph
    self.rule = rule
  }
  
  public func recomputeIfNeeded() {
    
    // record dependency
    if let c = graph.currentNode {
      let edge = Edge(from: self, to: c)
      outgoingEdges.append(edge)
      c.incomingEdges.append(edge)
    }
        
    if !potentiallyDirty && _cachedValue != nil { return }
    
    for edge in incomingEdges {
      edge.from.recomputeIfNeeded()
    }
    
    let hasPendingIncomingEdge = incomingEdges.contains(where: \.isPending)
    
    if hasPendingIncomingEdge || _cachedValue == nil {
      let previousNode = graph.currentNode
      defer { graph.currentNode = previousNode }
      graph.currentNode = self
      let isInitial = _cachedValue == nil
      removeIncomingEdges()
      _cachedValue = rule(graph)
      // TODO only if _cachedValue has changed
      if !isInitial {
        for o in outgoingEdges {
          o.isPending = true
        }      
      }
    }
    
    potentiallyDirty = false
    
  }
  
  func removeIncomingEdges() {
    for e in incomingEdges {
      e.from.outgoingEdges.removeAll(where: { $0 === e })
    }
    incomingEdges = []
  }
  
  @inline(__always)
  private func prepareObservationRegistrar() {
    if observationRegistrar == nil {
      observationRegistrar = .init()
    }
  }
  
  deinit {    
    Log.generic.debug("Deinit Computed: \(self.name)")
  }
  
  private var _sink: Sink = .init()
  
  public func onChange() -> AsyncStream<Void> {
    _sink.addStream()
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
