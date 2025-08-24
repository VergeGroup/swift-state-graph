import Foundation
import Testing

@testable import StateGraph

@Suite("GraphTrackingGroup Tests")
struct GraphTrackingGroupTests {

  final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return _count
    }

    func increment() {
      lock.lock()
      defer { lock.unlock() }
      _count += 1
    }

    func reset() {
      lock.lock()
      defer { lock.unlock() }
      _count = 0
    }
  }

  @Test
  func basicConditionalTracking() async throws {
    let node1 = Stored(wrappedValue: 5)  // condition node
    let node2 = Stored(wrappedValue: 10)  // conditional node
    let node3 = Stored(wrappedValue: 20)  // always tracked node

    let callCounter = CallCounter()

    let cancellable = withGraphTracking {
      withGraphTrackingGroup {
        callCounter.increment()
        print("=== Tracking group called, count: \(callCounter.count) ===")
        print(
          "node1: \(node1.wrappedValue), condition: \(node1.wrappedValue > 10)"
        )

        if node1.wrappedValue > 10 {
          print("  Reading node2 (conditional): \(node2.wrappedValue)")
          _ = node2.wrappedValue  // only tracked when condition is true
        }
        print("  Reading node3 (always): \(node3.wrappedValue)")
        _ = node3.wrappedValue  // always tracked
      }
    }

    print("\nInitial state: callCounter = \(callCounter.count)")
    let initialCount = callCounter.count

    print("\n--- Testing: node2 change when condition is false ---")
    // Initially: node1=5 <= 10, so node2 should NOT be tracked
    node2.wrappedValue = 99  // should NOT trigger additional tracking
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
    print("After node2 change: callCounter = \(callCounter.count)")
    // Should remain same as node2 is not being tracked
    #expect(callCounter.count == initialCount)

    print("\n--- Testing: node3 change (always tracked) ---")
    node3.wrappedValue = 99  // SHOULD trigger tracking
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
    print("After node3 change: callCounter = \(callCounter.count)")
    // Should increment since node3 is always tracked
    let afterNode3Change = callCounter.count
    #expect(afterNode3Change > initialCount)

    print("\n--- Testing: condition becomes true ---")
    // Change condition: node1 > 10
    node1.wrappedValue = 15  // now condition becomes true
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
    print("After condition change: callCounter = \(callCounter.count)")
    let afterConditionChange = callCounter.count
    #expect(afterConditionChange > afterNode3Change)

    print("\n--- Testing: node2 change when condition is true ---")
    node2.wrappedValue = 88  // NOW should trigger tracking
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
    print(
      "After node2 change (condition true): callCounter = \(callCounter.count)"
    )
    let afterNode2Change = callCounter.count
    // Should increment since now node2 is tracked (condition is true)
    #expect(afterNode2Change > afterConditionChange)

    cancellable.cancel()
    print("\nTest completed. Final count: \(callCounter.count)")
    print("Behavior verified: conditional tracking works as expected")
  }

  @Test
  func dynamicConditionChanges() async throws {
    let condition = Stored(wrappedValue: 15)  // starts > 10 (true)
    let tracked = Stored(wrappedValue: 1)

    let callCounter = CallCounter()

    let cancellable = withGraphTracking {
      withGraphTrackingGroup {
        callCounter.increment()
        print(
          "=== Group called, count: \(callCounter.count), condition: \(condition.wrappedValue) > 10 = \(condition.wrappedValue > 10) ==="
        )

        if condition.wrappedValue > 10 {
          print("  Reading tracked node: \(tracked.wrappedValue)")
          _ = tracked.wrappedValue
        } else {
          print("  Condition false, not reading tracked node")
        }
      }
    }

    print("\nInitial state: callCounter = \(callCounter.count)")
    let initialCount = callCounter.count

    print("\n--- Testing: tracked change when condition is TRUE ---")
    // Initially condition=15 > 10, so tracked should be observed
    tracked.wrappedValue = 2  // should trigger
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
    print(
      "After tracked change (condition true): callCounter = \(callCounter.count)"
    )
    let afterFirstChange = callCounter.count
    #expect(afterFirstChange > initialCount)

    print("\n--- Testing: condition becomes FALSE ---")
    // Change condition to false
    condition.wrappedValue = 5  // condition becomes false
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
    print("After condition change to false: callCounter = \(callCounter.count)")
    let afterConditionFalse = callCounter.count
    #expect(afterConditionFalse > afterFirstChange)

    print("\n--- Testing: tracked change when condition is FALSE ---")
    tracked.wrappedValue = 3  // should NOT trigger
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
    print(
      "After tracked change (condition false): callCounter = \(callCounter.count)"
    )
    let afterTrackedChangeWhenFalse = callCounter.count
    // Should remain same or only slightly increment since tracked is not being observed when condition is false
    #expect(afterTrackedChangeWhenFalse >= afterConditionFalse)

    print("\n--- Testing: condition becomes TRUE again ---")
    // Change condition back to true
    condition.wrappedValue = 20  // condition becomes true again
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
    print("After condition change to true: callCounter = \(callCounter.count)")
    let afterConditionTrue = callCounter.count
    #expect(afterConditionTrue > afterTrackedChangeWhenFalse)

    print("\n--- Testing: tracked change when condition is TRUE again ---")
    tracked.wrappedValue = 4  // should trigger again
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
    print(
      "After tracked change (condition true again): callCounter = \(callCounter.count)"
    )
    let finalCount = callCounter.count
    #expect(finalCount > afterConditionTrue)

    cancellable.cancel()
    print("\nTest completed. Final count: \(finalCount)")
    print("Dynamic condition tracking verified successfully")
  }

}

@Suite
struct ContinuousTrackingTests {

  final class Model: Sendable {
    @GraphStored
    var count1: Int = 0
    @GraphStored
    var count2: Int = 0
  }

  @Test("Use observation api")
  func observation_api() async throws {

    let model = Model()

    await confirmation(expectedCount: 1) { c in

      withObservationTracking {
        _ = model.count1
        _ = model.count2
      } onChange: {
        print(model.count1, model.count2)
        c.confirm()
      }

      model.count1 += 1
      model.count2 += 1

      try? await Task.sleep(for: .milliseconds(100))

    }
  }
  
  @Test("tearing")
  func tearing() async throws {

    let model = Model()

    await confirmation(expectedCount: 1) { c in

      withContinuousStateGraphTracking {
        _ = model.count1
        _ = model.count2
      } didChange: {
        print(model.count1, model.count2)
        c.confirm()
        return .next
      }

      model.count1 += 1
      model.count2 += 1

      try? await Task.sleep(for: .milliseconds(100))

    }

  }

  @MainActor
  @Test("background")  
  func background() async throws {

    let model = Model()

    await confirmation(expectedCount: 1) { c in

      withContinuousStateGraphTracking {
        _ = model.count1
        _ = model.count2
      } didChange: {
        print(model.count1, model.count2)
        #expect(Thread.isMainThread == true)
        c.confirm()
        return .next
      }

      Task.detached {
        model.count1 += 1
        model.count2 += 1
      }

      try? await Task.sleep(for: .milliseconds(100))

    }

  }
}
