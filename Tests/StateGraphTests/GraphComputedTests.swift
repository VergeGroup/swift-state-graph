#if compiler(>=6.4)
import Testing
import StateGraph

@Suite
struct GraphComputedTests {

  @Test
  func computedBodyReadsThroughComputedNode() {
    let model = ComputedBodyModel()

    #expect(model.doubledComputeCount == 0)
    #expect(model.$doubled === model.$doubled)
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

  @Test
  func nestedModelUsesItsOwnTypeAndBothMacroForms() {
    let model = ComputedNamespace.Model()

    #expect(model.total == 3)
    #expect(model.$total === model.$total)
    model.count = 4
    #expect(model.doubled == 8)
    #expect(model.total == 12)
  }
}

private let topLevelComputedBodyComputeCount = OSAllocatedUnfairLock<Int>(initialState: 0)

@GraphStored
private var topLevelComputedBodyCount: Int = 1

@GraphComputed
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

@GraphComputed
nonisolated private var nonisolatedTopLevelComputedBodyDoubled: Int {
  nonisolatedTopLevelComputedBodyComputeCount.withLock { $0 += 1 }
  return nonisolatedTopLevelComputedBodyCount * 2
}

private var nonisolatedTopLevelComputedBodyDoubledComputeCount: Int {
  nonisolatedTopLevelComputedBodyComputeCount.withLock { $0 }
}

/// Counts evaluations independently of the tracked source value.
private final class ComputedBodyModel {

  var doubledComputeCount: Int = 0

  @GraphStored
  var count: Int = 1

  @GraphComputed
  var doubled: Int {
    doubledComputeCount += 1
    return count * 2
  }
}

/// Exercises lazy node storage on a namespace without an instance owner.
private enum StaticComputedBodyModel {

  static let doubledComputeCount = OSAllocatedUnfairLock<Int>(initialState: 0)

  @GraphStored
  static var count: Int = 1

  @GraphComputed
  static var doubled: Int {
    doubledComputeCount.withLock { $0 += 1 }
    return count * 2
  }
}

/// Ensures macro expansion resolves the nearest owner when types are nested.
private enum ComputedNamespace {
  final class Model {
    @GraphStored var count: Int = 1
    @GraphComputedNode var doubled: Int

    @GraphComputed var total: Int {
      count + doubled
    }

    init() {
      $doubled = .init { [count = $count] _ in count.wrappedValue * 2 }
    }
  }
}
#endif
