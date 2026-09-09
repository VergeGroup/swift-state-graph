import Testing
import StateGraph

@Suite
struct GraphComputedNodeTests {

  @Test
  func explicitNodeCachesReadsAndTracksDependencies() {
    let count = Stored(wrappedValue: 1)
    let computations = OSAllocatedUnfairLock(initialState: 0)
    let node = Computed<Int> { _ in
      computations.withLock { $0 += 1 }
      return count.wrappedValue * 2
    }
    let model = ExplicitComputedModel(node: node)

    #expect(model.$doubled === node)
    #expect(computations.withLock { $0 } == 0)
    #expect(model.doubled == 2)
    #expect(model.doubled == 2)
    #expect(computations.withLock { $0 } == 1)

    count.wrappedValue = 3

    #expect(computations.withLock { $0 } == 1)
    #expect(model.doubled == 6)
    #expect(computations.withLock { $0 } == 2)
  }

  @Test
  func projectedNodeCanOutliveItsOwner() {
    let count = Stored(wrappedValue: 1)
    let node: Computed<Int>
    weak var releasedModel: ExplicitComputedModel?

    do {
      let model = ExplicitComputedModel(node: Computed { _ in count.wrappedValue * 2 })
      releasedModel = model
      #expect(model.doubled == 2)
      node = model.$doubled
    }

    #expect(releasedModel == nil)
    count.wrappedValue = 4
    #expect(node.wrappedValue == 8)
  }

  @Test
  func valueTypeCanExposeAnExplicitNode() {
    let count = Stored(wrappedValue: 1)
    let model = ExplicitComputedValue(node: Computed { _ in count.wrappedValue * 2 })
    let copy = model

    #expect(model.$doubled === copy.$doubled)
    count.wrappedValue = 5
    #expect(model.doubled == 10)
    #expect(copy.doubled == 10)
  }
}

/// Exposes a node whose capture list determines its lifetime independently of this model.
private final class ExplicitComputedModel {
  @GraphComputedNode var doubled: Int

  init(node: Computed<Int>) {
    $doubled = node
  }
}

/// Shares an explicitly supplied computed node across value copies.
private struct ExplicitComputedValue {
  @GraphComputedNode var doubled: Int

  init(node: Computed<Int>) {
    $doubled = node
  }
}
