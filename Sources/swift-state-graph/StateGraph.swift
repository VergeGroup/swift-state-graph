
public final class AttributeGraph {

  var nodes: [AnyNode] = []
  var currentNode: AnyNode?
  
  public init() {}

  public func input<Value>(name: String, _ value: Value) -> Node<Value> {
    let n = Node(name: name, in: self, wrappedValue: value)
    nodes.append(n)
    return n
  }

  public func rule<Value>(name: String, _ rule: @escaping () -> Value) -> Node<Value> {
    let n = Node(name: name, in: self, rule: rule)
    nodes.append(n)
    return n
  }

  public func graphViz() -> String {
    let nodesStr = nodes.map {
      "\($0.name)\($0.potentiallyDirty ? " [style=dashed]" : "")"
    }.joined(separator: "\n")
    let edges = nodes.flatMap(\.outgoingEdges).map {
      "\($0.from.name) -> \($0.to.name)\($0.isPending ? " [style=dashed]" : "")"
    }.joined(separator: "\n")
    return """
        digraph {
        \(nodesStr)
        \(edges)
        }
        """
  }
}

public protocol AnyNode: AnyObject {
  var name: String { get }
  /// edges affecting nodes
  var outgoingEdges: [Edge] { get }
  /// inverse edges that depending on nodes
  var incomingEdges: [Edge] { get set }
  
  var potentiallyDirty: Bool { get set }
}

public final class Node<Value>: AnyNode {

  unowned var graph: AttributeGraph
  private var _cachedValue: Value?

  public var potentiallyDirty: Bool = false {
    didSet {
      guard potentiallyDirty, potentiallyDirty != oldValue else { return }
      for e in outgoingEdges {
        e.to.potentiallyDirty = true
      }
    }
  }
  
  public var name: String

  public var wrappedValue: Value {
    get {
      recomputeIfNeeded()
      return _cachedValue!
    }
    set {
      assert(rule == nil)
      _cachedValue = newValue
      
      for e in outgoingEdges {
        e.isPending = true
        e.to.potentiallyDirty = true
      }
      
    }
  }

  var rule: (() -> Value)?
  public var incomingEdges: [Edge] = []
  public var outgoingEdges: [Edge] = []

  init(
    name: String,
    in graph: AttributeGraph,
    wrappedValue: Value
  ) {
    self.name = name
    self.graph = graph
    self._cachedValue = wrappedValue
  }

  init(
    name: String,
    in graph: AttributeGraph,
    rule: @escaping () -> Value
  ) {
    self.name = name
    self.graph = graph
    self.rule = rule
  }

  private func recomputeIfNeeded() {
    if let c = graph.currentNode {
      // self affects c
      let edge = Edge(from: self, to: c)          
      outgoingEdges.append(edge)
      c.incomingEdges.append(edge)
    }
    if _cachedValue == nil, let rule {
      let previousNode = graph.currentNode
      defer { graph.currentNode = previousNode }
      graph.currentNode = self
      _cachedValue = rule()
    }
  }
}

@DebugDescription
public final class Edge: CustomDebugStringConvertible {

  unowned var from: AnyNode
  unowned var to: AnyNode
  
  var isPending: Bool = false

  init(from: AnyNode, to: AnyNode) {
    self.from = from
    self.to = to
  }

  public var debugDescription: String {
    "\(from.name) -> \(to.name)"
  }
}

