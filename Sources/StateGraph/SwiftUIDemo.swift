#if DEBUG

  import SwiftUI

  @MainActor
  let graph: StateGraph = .init()

  private struct _Book: View {

    let node: StoredNode<Int>

    init(node: StoredNode<Int>) {
      self.node = node
    }

    var body: some View {
      VStack {
        Text("\(node.wrappedValue)")
        Button("+1") {
          node.wrappedValue += 1
        }
      }
    }
  }

  #Preview("_Book") {
    _Book(
      node: graph.input(name: "A", 1)
    )
    .frame(width: 300, height: 300)
  }

#endif
