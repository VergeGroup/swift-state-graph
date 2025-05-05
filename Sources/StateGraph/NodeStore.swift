
/// for debugging
actor NodeStore {
  
  var nodes: ContiguousArray<WeakNode> = []
  
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
