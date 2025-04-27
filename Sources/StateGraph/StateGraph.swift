import Combine

public final class StateGraph {

  var nodes: [any Node] = []
  var currentNode: (any Node)?
      
  public init() {}
  
  public func input<Value>(
    name: String,
    _ value: Value
  ) -> StoredNode<Value> {
    let n = StoredNode(name: name, in: self, wrappedValue: value)
    nodes.append(n)   
    return n
  }

  public func rule<Value>(
    name: String,
    _ rule: @escaping (StateGraph) -> Value
  ) -> ComputedNode<Value> {
    let n = ComputedNode(name: name, in: self, rule: rule)
    nodes.append(n)
    return n
  }
      
  public func graphViz() -> String {
    let nodesStr = nodes.map {
      "\($0.name)\($0.potentiallyDirty ? " [style=dashed]" : "")"
    }.joined(separator: "\n")
    let edges = nodes
      .flatMap(\.outgoingEdges)
      .map {
        "\($0.from.name) -> \($0.to.name)\($0.isPending ? " [style=dashed]" : "")"
      }
      .sorted()
      .joined(separator: "\n")
  
    return """
        digraph {
        \(nodesStr)
        \(edges)
        }
        """
  }
    
}

public protocol Node: AnyObject {
  var name: String { get }
  /// edges affecting nodes
  var outgoingEdges: [Edge] { get set }
  /// inverse edges that depending on nodes
  var incomingEdges: [Edge] { get set }
  
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
public final class StoredNode<Value>: Node {
  
  unowned let graph: StateGraph
  private var value: Value
  
  public var potentiallyDirty: Bool = false {
    didSet {
      guard potentiallyDirty, potentiallyDirty != oldValue else { return }
      for e in outgoingEdges {
        e.to.potentiallyDirty = true
      }
      if let continuation {
        continuation.yield(())
      }
    }
  }
  
  public let name: String
  
  public var wrappedValue: Value {
    get {
      // record dependency
      if let c = graph.currentNode {
        let edge = Edge(from: self, to: c)
        outgoingEdges.append(edge)
        c.incomingEdges.append(edge)
      }
      return value
    }
    set {
      value = newValue
      
      propagateDirty()    
    }
  }
    
  public var incomingEdges: [Edge] = []
  public var outgoingEdges: [Edge] = []
  
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
    if let continuation {
      continuation.yield(())
    }
  }
  
  public func recomputeIfNeeded() {
    // no operation
  }
  
  deinit {    
    Log.generic.debug("Deinit Stored: \(self.name)")
  }
    
  private var continuation: AsyncStream<Void>.Continuation?
  
  public func onChange() -> AsyncStream<Void> {
    return AsyncStream { continuation in
      self.continuation = continuation
    }
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
public final class ComputedNode<Value>: Node {
  
  unowned let graph: StateGraph
  private var _cachedValue: Value?
  
  public var potentiallyDirty: Bool = false {
    didSet {
      guard potentiallyDirty, potentiallyDirty != oldValue else { return }
      for e in outgoingEdges {
        e.to.potentiallyDirty = true
      }
      if let continuation {
        continuation.yield(())
      }
    }
  }
  
  public let name: String
  
  public var wrappedValue: Value {
    get {
      recomputeIfNeeded()
      return _cachedValue!
    }
    set {
      _cachedValue = newValue
      
      for e in outgoingEdges {
        e.isPending = true
        e.to.potentiallyDirty = true
      }
      
    }
  }
    
  let rule: ((StateGraph) -> Value)
  public var incomingEdges: [Edge] = []
  public var outgoingEdges: [Edge] = []
     
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
  
  deinit {    
    Log.generic.debug("Deinit Computed: \(self.name)")
  }
  
  private var continuation: AsyncStream<Void>.Continuation?
  
  public func onChange() -> AsyncStream<Void> {
    return AsyncStream { continuation in
      self.continuation = continuation
    }
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
