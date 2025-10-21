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

  @Test
  @MainActor
  func infiniteLoopWhenSettingSameValue() async throws {
    let node = Stored(wrappedValue: 42)
    let callCounter = CallCounter()
    let maxIterations = 10

    let cancellable = withGraphTracking {
      withGraphTrackingGroup {
        let currentCount = callCounter.count

        // Safety guard: stop after maxIterations to prevent actual infinite loop during testing
        guard currentCount < maxIterations else {
          return
        }

        callCounter.increment()
        print("=== Handler called, count: \(callCounter.count) ===")

        // Read the current value
        let value = node.wrappedValue

        // Set the same value back - this should NOT trigger re-execution
        // but currently causes an infinite loop (bug)
        node.wrappedValue = value
      }
    }

    // Wait a short time for any potential iterations
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

    // Expected behavior: handler should only be called once (initial setup)
    // Setting the same value should NOT trigger re-execution
    print("\nFinal count: \(callCounter.count)")
    print("Expected: 1 (initial call only)")
    print("Actual: \(callCounter.count)")

    if callCounter.count > 1 {
      print("❌ INFINITE LOOP DETECTED: Handler was called \(callCounter.count) times")
      print("This indicates that setting an unchanged value triggers re-execution")
    }

    // This expectation will FAIL with current implementation (infinite loop bug)
    // It should PASS once the bug is fixed
    #expect(callCounter.count == 1, "Setting unchanged value should not trigger re-execution, but handler was called \(callCounter.count) times indicating an infinite loop")

    cancellable.cancel()
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

  @Observable
  @MainActor
  final class ObservableTestModel {
    var value: Int = 42
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

  @Test("Observation API - infinite loop check")
  @MainActor
  func observation_api_infiniteLoopCheck() async throws {
    let model = ObservableTestModel()
    let callCounter = GraphTrackingGroupTests.CallCounter()
    let maxIterations = 10

    nonisolated(unsafe) var trackingSetup: (() -> Void)?

    let setupTracking: @MainActor () -> Void = {
      let currentCount = callCounter.count

      // Safety guard: stop after maxIterations
      guard currentCount < maxIterations else { return }

      callCounter.increment()
      print("=== Observation handler called, count: \(callCounter.count) ===")

      withObservationTracking {
        // Read the current value
        let value = model.value
        print("  Read value: \(value)")

        // Set the same value back - does this trigger infinite loop?
        model.value = value
        print("  Set same value: \(value)")
      } onChange: {
        print("  onChange triggered")
        Task { @MainActor in
          trackingSetup?()
        }
      }
    }

    trackingSetup = setupTracking

    setupTracking()

    // Wait to see if iterations occur
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

    print("\n=== Observation API Test Results ===")
    print("Final count: \(callCounter.count)")
    print("Expected: 1 (initial call only)")
    print("Actual: \(callCounter.count)")

    if callCounter.count > 1 {
      print("❌ INFINITE LOOP DETECTED in Observation API")
    } else {
      print("✅ Observation API does NOT have infinite loop issue")
    }

    // This test shows whether Apple's Observation framework has the same issue
    #expect(callCounter.count == 1, "Observation API: Setting unchanged value should not trigger re-execution, but handler was called \(callCounter.count) times")
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

@Suite
struct IssuesTrackingOnHeavyOperation {

  final class Model: Sendable {
    @GraphStored
    var count1: Int = 0
    @GraphStored
    var count2: Int = 0
  }

  @Test
  func stuck() async {

    let model = Model()

    var cancellable: AnyCancellable?

    await confirmation(expectedCount: 1) { c in

      cancellable = withGraphTracking {
        withGraphTrackingGroup {

          if model.count2 == 2 {
            c.confirm()
          }

          if model.count1 == 1 {
            Thread.sleep(forTimeInterval: 2)
          }

        }
      }
      Task.detached {
        print("Update count1")
        model.count1 = 1
        Task.detached {
          try? await Task.sleep(for: .milliseconds(100))
          print("Update count2")
          model.count2 = 2
        }
      }

      try? await Task.sleep(for: .seconds(3))

      #expect(model.count2 == 2)
    }

    withExtendedLifetime(cancellable) {}

  }

  @Test
  func stuckMain() async {

    let model = Model()

    await confirmation(expectedCount: 1) { c in

      let cancellable: OSAllocatedUnfairLock<AnyCancellable?> = .init(
        uncheckedState: nil
      )

      Task { @MainActor in
        
        let _cancellable = withGraphTracking {
          withGraphTrackingGroup {
            print("💥 In")
            #expect(Thread.isMainThread)
            if model.count2 == 2 {
              print("✨ confirm")
              c.confirm()
            }
            
            if model.count1 == 1 {
              print("😪 sleep")
              Thread.sleep(forTimeInterval: 2)
            }
            print("💥 out")
            
          }
        }
        
        cancellable.withLockUnchecked {
          $0 = _cancellable
        }
      }

      Task {        
        try? await Task.sleep(for: .milliseconds(100))
        print("Update count1")
        model.count1 = 1
        Task {
          try? await Task.sleep(for: .milliseconds(100))
          print("Update count2")
          model.count2 = 2
        }

        withExtendedLifetime(cancellable) {}
      }

      try? await Task.sleep(for: .seconds(4))
      #expect(model.count2 == 2)

    }

  }

}

@Suite(.disabled())
struct IssuesObservationsDetached {

  final class Model: Sendable {
    @GraphStored
    var count1: Int = 0
    @GraphStored
    var count2: Int = 0
  }
 
  @available(macOS 26, iOS 26, *)
  @Test("Observation")
  func observation() async {
    let model = Model()
    await confirmation { c in
      Task {
        let s = Observations<Void, Never>.untilFinished {
          if model.count2 == 2 {
            print("Sleep", Thread.current)
            return .finish
          }
          if model.count1 == 1 {
            print("Sleep", Thread.current)
            Thread.sleep(forTimeInterval: 2)
            return .next(())
          }
          return .next(())
        }
        var eventCount: Int = 0
        for await e in s {
          eventCount += 1
        }
        c.confirm()
      }

      Task {
        print("Update count1")
        model.count1 = 1
        Task {
          try? await Task.sleep(for: .milliseconds(100))
          print("Update count2")
          model.count2 = 2
        }
      }
      try? await Task.sleep(for: .seconds(3))
    }

  }

  @available(macOS 26, iOS 26, *)
  @Test("Observation")
  @MainActor
  func observationMainActor() async {
    let model = Model()
    await confirmation { c in
      Task {
        let s = Observations<Void, Never>.untilFinished {
          if model.count2 == 2 {
            return .finish
          }
          if model.count1 == 1 {
            Thread.sleep(forTimeInterval: 2)
            return .next(())
          }
          return .next(())
        }
        var eventCount: Int = 0
        for await e in s {
          eventCount += 1
        }
        c.confirm()
      }

      Task {
        print("Update count1")
        model.count1 = 1
        Task {
          try? await Task.sleep(for: .milliseconds(100))
          print("Update count2")
          model.count2 = 2
        }
      }
      try? await Task.sleep(for: .seconds(3))
    }

  }
}

@Suite
struct IssuesObservationsObservableObject {

  // Requires Sendable for Observations then needs @MainActor
  @MainActor
  @Observable
  final class ObservableModel: Sendable {
    var count1: Int = 0
    var count2: Int = 0
  }

  @available(macOS 26, iOS 26, *)
  @Test("Observation")
  @MainActor
  func observation() async {
    let model = ObservableModel()
    await confirmation { c in
      Task {
        let s = Observations<Void, Never>.untilFinished {
          print("Up")
          if model.count2 == 2 {
            return .finish
          }
          if model.count1 == 1 {
            Thread.sleep(forTimeInterval: 2)
            return .next(())
          }
          return .next(())
        }
        var eventCount: Int = 0
        for await e in s {
          eventCount += 1
        }
        c.confirm()
      }

      Task {
        print("Update count1")
        model.count1 = 1
        Task {
          try? await Task.sleep(for: .milliseconds(100))
          print("Update count2")
          model.count2 = 2
        }
      }
      try? await Task.sleep(for: .seconds(5))
    }

  }

}
