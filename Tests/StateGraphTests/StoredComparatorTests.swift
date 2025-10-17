import Observation
import Testing

@testable import StateGraph

@Suite
struct StoredComparatorTests {

  @Test
  func observation_willSet_didSet_not_called_for_same_value() async {
    // Given: A model with GraphStored property
    final class Model: Sendable {
      @GraphStored var count: Int = 0
    }

    let model = Model()

    // When: Observing changes and setting the same value
    await confirmation(expectedCount: 0) { c in
      withObservationTracking {
        _ = model.count
      } onChange: {
        c.confirm()
      }

      model.count = 0  // Same value - should NOT trigger onChange

      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  @Test
  func observation_willSet_didSet_called_for_different_value() async {
    // Given: A model with GraphStored property
    final class Model: Sendable {
      @GraphStored var count: Int = 0
    }

    let model = Model()

    // When: Observing changes and setting a different value
    await confirmation(expectedCount: 1) { c in
      withObservationTracking {
        _ = model.count
      } onChange: {
        Task {
          #expect(model.count == 1)
          c.confirm()
        }
      }

      model.count = 1  // Different value - should trigger onChange

      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  @Test
  func multiple_same_value_updates_no_notifications() async {
    // Given: A model with GraphStored property
    final class Model: Sendable {
      @GraphStored var value: String = "initial"
    }

    let model = Model()

    // When: Setting same value multiple times
    await confirmation(expectedCount: 0) { c in
      withObservationTracking {
        _ = model.value
      } onChange: {
        c.confirm()
      }

      model.value = "initial"
      model.value = "initial"
      model.value = "initial"

      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  @Test
  func state_graph_tracking_no_notification_for_same_value() async {
    // Given: A model with GraphStored property
    final class Model: Sendable {
      @GraphStored var count: Int = 10
    }

    let model = Model()

    // When: Using StateGraph's tracking and setting same value
    await confirmation(expectedCount: 0) { c in
      withStateGraphTracking {
        _ = model.count
      } didChange: {
        c.confirm()
      }

      model.count = 10  // Same value - should NOT trigger

      try? await Task.sleep(for: .milliseconds(100))
    }
  }

  @Test
  func computed_node_not_invalidated_for_same_stored_value() async {
    // Given: Stored node and computed node
    let stored = Stored(name: "stored", wrappedValue: 5)

    let computeCount = OSAllocatedUnfairLock(initialState: 0)
    let computed = Computed(name: "computed") { _ in
      computeCount.withLock { $0 += 1 }
      return stored.wrappedValue * 2
    }

    // Trigger initial computation
    #expect(computed.wrappedValue == 10)
    #expect(computeCount.withLock { $0 } == 1)

    // When: Set the same value
    stored.wrappedValue = 5

    // Then: Computed should not be marked as dirty and not recompute
    #expect(computed.wrappedValue == 10)
    #expect(computeCount.withLock { $0 } == 1, "Computed node should not recompute for same stored value")
  }

  @Test
  func onChange_callback_not_invoked_for_same_value() async {
    // Given: Stored node with onChange callback
    let stored = Stored(name: "stored", wrappedValue: 100)

    var changeCount = 0

    let cancellable = withGraphTracking {
      stored.onChange { newValue in
        changeCount += 1
      }
    }

    // Initial state
    #expect(changeCount == 1)

    // When: Set the same value multiple times
    stored.wrappedValue = 100
    stored.wrappedValue = 100

    try? await Task.sleep(for: .milliseconds(50))

    // Then: onChange should not be invoked
    #expect(changeCount == 1, "onChange should not be called for same value")

    // When: Set a different value
    stored.wrappedValue = 200

    try? await Task.sleep(for: .milliseconds(50))

    // Then: onChange should be invoked
    #expect(changeCount == 2, "onChange should be called once for different value")

    withExtendedLifetime(cancellable, {})
  }

  @Test
  func equatable_custom_struct_comparison() async {
    // Given: Custom Equatable struct
    struct Point: Equatable {
      let x: Int
      let y: Int
    }

    let stored = Stored(name: "point", wrappedValue: Point(x: 10, y: 20))

    let computeCount = OSAllocatedUnfairLock(initialState: 0)
    let computed = Computed(name: "computed") { _ in
      computeCount.withLock { $0 += 1 }
      return stored.wrappedValue.x + stored.wrappedValue.y
    }

    // Trigger initial computation
    #expect(computed.wrappedValue == 30)
    #expect(computeCount.withLock { $0 } == 1)

    // When: Set equivalent struct (same values)
    stored.wrappedValue = Point(x: 10, y: 20)

    // Then: Should not recompute
    #expect(computed.wrappedValue == 30)
    #expect(computeCount.withLock { $0 } == 1, "Same struct values should not trigger recomputation")

    // When: Set different struct
    stored.wrappedValue = Point(x: 15, y: 25)

    // Then: Should recompute
    #expect(computed.wrappedValue == 40)
    #expect(computeCount.withLock { $0 } == 2, "Different struct values should trigger recomputation")
  }

}
