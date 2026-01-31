import Foundation

/// handler実行中にアクセスされたノードを収集するコレクター
struct NodeTraceCollector: @unchecked Sendable {

  private let storage = Storage()

  private final class Storage {
    var nodes: [any TypeErasedNode] = []
  }

  func append(_ node: any TypeErasedNode) {
    storage.nodes.append(node)
  }

  func drain() -> [any TypeErasedNode] {
    let result = storage.nodes
    storage.nodes = []
    return result
  }
}
