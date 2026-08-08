#if compiler(>=6.4) && SSG_ENABLE_COMPUTED_BODY_TESTS
import Testing
import StateGraph

@Suite
struct ComputedBodyMacroTests {

  @Test
  func computedBodyReadsThroughComputedNode() {
    let model = ComputedBodyModel()

    #expect(model.doubledComputeCount == 0)

    #expect(model.doubled == 2)
    #expect(model.doubledComputeCount == 1)

    #expect(model.doubled == 2)
    #expect(model.doubledComputeCount == 1)

    model.count = 3
    #expect(model.doubledComputeCount == 1)

    #expect(model.doubled == 6)
    #expect(model.doubledComputeCount == 2)

    #expect(model.doubled == 6)
    #expect(model.doubledComputeCount == 2)
  }

  @Test
  func topLevelComputedBodyReadsThroughComputedNode() {
    topLevelComputedBodyCount = 1
    topLevelComputedBodyComputeCount.withLock { $0 = 0 }

    #expect(topLevelComputedBodyDoubledComputeCount == 0)

    #expect(topLevelComputedBodyDoubled == 2)
    #expect(topLevelComputedBodyDoubledComputeCount == 1)

    #expect(topLevelComputedBodyDoubled == 2)
    #expect(topLevelComputedBodyDoubledComputeCount == 1)

    topLevelComputedBodyCount = 3
    #expect(topLevelComputedBodyDoubledComputeCount == 1)

    #expect(topLevelComputedBodyDoubled == 6)
    #expect(topLevelComputedBodyDoubledComputeCount == 2)

    #expect(topLevelComputedBodyDoubled == 6)
    #expect(topLevelComputedBodyDoubledComputeCount == 2)
  }

  @Test
  func nonisolatedTopLevelComputedBodyCompilesAndReadsThroughComputedNode() {
    nonisolatedTopLevelComputedBodyCount = 1
    nonisolatedTopLevelComputedBodyComputeCount.withLock { $0 = 0 }

    #expect(nonisolatedTopLevelComputedBodyDoubledComputeCount == 0)

    #expect(nonisolatedTopLevelComputedBodyDoubled == 2)
    #expect(nonisolatedTopLevelComputedBodyDoubledComputeCount == 1)

    #expect(nonisolatedTopLevelComputedBodyDoubled == 2)
    #expect(nonisolatedTopLevelComputedBodyDoubledComputeCount == 1)

    nonisolatedTopLevelComputedBodyCount = 3
    #expect(nonisolatedTopLevelComputedBodyDoubledComputeCount == 1)

    #expect(nonisolatedTopLevelComputedBodyDoubled == 6)
    #expect(nonisolatedTopLevelComputedBodyDoubledComputeCount == 2)

    #expect(nonisolatedTopLevelComputedBodyDoubled == 6)
    #expect(nonisolatedTopLevelComputedBodyDoubledComputeCount == 2)
  }

  @Test
  func staticComputedBodyReadsThroughComputedNode() {
    StaticComputedBodyModel.count = 1
    StaticComputedBodyModel.doubledComputeCount.withLock { $0 = 0 }

    #expect(StaticComputedBodyModel.doubledComputeCount.withLock { $0 } == 0)

    #expect(StaticComputedBodyModel.doubled == 2)
    #expect(StaticComputedBodyModel.doubledComputeCount.withLock { $0 } == 1)

    #expect(StaticComputedBodyModel.doubled == 2)
    #expect(StaticComputedBodyModel.doubledComputeCount.withLock { $0 } == 1)

    StaticComputedBodyModel.count = 3
    #expect(StaticComputedBodyModel.doubledComputeCount.withLock { $0 } == 1)

    #expect(StaticComputedBodyModel.doubled == 6)
    #expect(StaticComputedBodyModel.doubledComputeCount.withLock { $0 } == 2)

    #expect(StaticComputedBodyModel.doubled == 6)
    #expect(StaticComputedBodyModel.doubledComputeCount.withLock { $0 } == 2)
  }
}

private let topLevelComputedBodyComputeCount = OSAllocatedUnfairLock<Int>(initialState: 0)

@GraphStored
private var topLevelComputedBodyCount: Int = 1

@GraphComputedBody
private var topLevelComputedBodyDoubled: Int {
  topLevelComputedBodyComputeCount.withLock { $0 += 1 }
  return topLevelComputedBodyCount * 2
}

private var topLevelComputedBodyDoubledComputeCount: Int {
  topLevelComputedBodyComputeCount.withLock { $0 }
}

private let nonisolatedTopLevelComputedBodyComputeCount = OSAllocatedUnfairLock<Int>(initialState: 0)

@GraphStored
nonisolated private var nonisolatedTopLevelComputedBodyCount: Int = 1

@GraphComputedBody
nonisolated private var nonisolatedTopLevelComputedBodyDoubled: Int {
  nonisolatedTopLevelComputedBodyComputeCount.withLock { $0 += 1 }
  return nonisolatedTopLevelComputedBodyCount * 2
}

private var nonisolatedTopLevelComputedBodyDoubledComputeCount: Int {
  nonisolatedTopLevelComputedBodyComputeCount.withLock { $0 }
}

private final class ComputedBodyModel {

  var doubledComputeCount: Int = 0

  @GraphStored
  var count: Int = 1

  @GraphComputedBody
  var doubled: Int {
    doubledComputeCount += 1
    return count * 2
  }
}

private enum StaticComputedBodyModel {

  static let doubledComputeCount = OSAllocatedUnfairLock<Int>(initialState: 0)

  @GraphStored
  static var count: Int = 1

  @GraphComputedBody
  static var doubled: Int {
    doubledComputeCount.withLock { $0 += 1 }
    return count * 2
  }
}
#endif
