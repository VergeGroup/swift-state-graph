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
    func name(_ node: any TypeErasedNode) -> String {
      return #""\#(node.info.id)_\#(node.info.typeName)""#
    }

    let grouped = Dictionary(grouping: nodes.compactMap { $0.value }) { $0.info.group }

    let clusters = grouped.compactMap { (group, nodes) -> String? in
      guard let group, !nodes.isEmpty else { return nil }
      let nodesStr = nodes.map { name($0) }.joined(separator: "\n")
      return """
      subgraph cluster_\(group) {
        label = \"\(group)\";
        \(nodesStr)
      }
      """
    }.joined(separator: "\n")

    // group == nil
    let ungrouped = (grouped[nil] ?? []).map { name($0) }.joined(separator: "\n")

    // edges
    let edges = nodes
      .compactMap { $0.value }
      .flatMap(\.outgoingEdges)
      .map {
        "\(name($0.from)) -> \(name($0.to))\($0.isPending ? " [style=dashed]" : "")"
      }.joined(separator: "\n")

    return """
      digraph StateGraph {
      
      \(clusters)
      
      \(ungrouped)
      
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
