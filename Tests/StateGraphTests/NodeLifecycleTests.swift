import StateGraph
import Testing

@Suite("Node Lifecycle Tests")
struct NodeLifecycleTests {

  @Test
  func releasingUpstreamComputedRemovesDownstreamEdge() async {
    let trigger = Stored(wrappedValue: 0)
    var upstream: Computed<Int>? = Computed { _ in 10 }
    weak let weakUpstream = upstream
    let downstream = Computed { [weak upstream] _ in
      (upstream?.wrappedValue ?? 0) + trigger.wrappedValue
    }

    #expect(downstream.wrappedValue == 10)

    upstream = nil

    for _ in 0..<100 where weakUpstream != nil {
      try? await Task.sleep(for: .milliseconds(1))
    }

    #expect(weakUpstream == nil)

    // A computed node cannot observe upstream deallocation as an invalidation event,
    // so it keeps serving its cached value until another dependency changes.
    #expect(downstream.wrappedValue == 10)

    trigger.wrappedValue = 1
    #expect(downstream.wrappedValue == 1)
  }
}
