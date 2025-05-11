/// for debugging
public actor NodeStore {

  public static let shared = NodeStore()

  private var nodes: ContiguousArray<WeakNode> = []

  func register(node: any TypeErasedNode) {
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
    
    func description(_ node: any TypeErasedNode) -> String {
      return "\(node.name)"
    }
    
    let nodesStr =
      nodes
      .compactMap { $0.value }
      .map {
        "\(description($0))"
      }.joined(separator: "\n")
    let edges =
      nodes
      .compactMap { $0.value }
      .flatMap(\.outgoingEdges).map {
        "\(description($0.from)) -> \(description($0.to))\($0.isPending ? " [style=dashed]" : "")"
      }.joined(separator: "\n")
    return """
      digraph {
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
