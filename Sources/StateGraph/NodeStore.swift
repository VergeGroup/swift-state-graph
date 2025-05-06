
/// for debugging
actor NodeStore {
  
  private var nodes: ContiguousArray<WeakNode> = []
  
  func register(node: any NodeType) {
    nodes.append(.init(node))
    compact()
  }
  
  private func compact() {
    nodes.removeAll {
      $0.value == nil
    }
  }
  
  static let shared = NodeStore()
}

private struct WeakNode: Equatable {
  
  static func == (lhs: WeakNode, rhs: WeakNode) -> Bool {
    return lhs.value === rhs.value
  }
  
  weak var value: (any NodeType)?
  
  init(_ value: any NodeType) {
    self.value = value
  }
}
