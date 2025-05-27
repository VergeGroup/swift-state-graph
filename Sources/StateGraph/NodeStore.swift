/// for debugging
public actor NodeStore {

  public static let shared = NodeStore()

  private var nodes: ContiguousArray<WeakNode> = []
  private var isEnabled: Bool = false
  
  public func enable() {
    isEnabled = true
  }
  
  public func disable() {
    isEnabled = false
    nodes.removeAll()
  }

  func register(node: any TypeErasedNode) {
    guard isEnabled else { return }
    nodes.append(.init(node))
    compact()  
  }

  private func compact() {
    nodes.removeAll {
      $0.value == nil
    }
  }
  
  public var _nodes: [any TypeErasedNode] {
    nodes.compactMap { $0.value }
  }

  public func graphViz() -> String {
    func name(_ node: any TypeErasedNode) -> String {
      return #""\#(node.info.name.map(String.init) ?? "noname")_\#(node.info.sourceLocation.text)""#
    }

    let allNodes = nodes.compactMap { $0.value }
    let nodesStr = allNodes.map { name($0) }.joined(separator: "\n")

    // edges
    let edges = allNodes
      .flatMap(\.outgoingEdges).map {
        "\(name($0.from)) -> \(name($0.to))\($0.isPending ? " [style=dashed]" : "")"
      }.joined(separator: "\n")

    return """
      digraph StateGraph {
      
      \(nodesStr)
      
      \(edges)
      }
      """
  }

}

private struct WeakNode: Equatable {

  static func == (lhs: WeakNode, rhs: WeakNode) -> Bool {
    return lhs.value === rhs.value
  }

  weak var value: (any TypeErasedNode)?

  init(_ value: any TypeErasedNode) {
    self.value = value
  }
}
