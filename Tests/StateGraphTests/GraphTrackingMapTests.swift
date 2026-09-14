import Foundation
import Testing

@testable import StateGraph

@Suite("GraphTrackingMap Tests")
struct GraphTrackingMapTests {

  @Test
  func basicProjection() async throws {
    let firstName = Stored(wrappedValue: "John")
    let lastName = Stored(wrappedValue: "Doe")

    var receivedValues: [String] = []

    await confirmation(expectedCount: 3) { confirm in
      let cancellable = withGraphTracking {
        withGraphTrackingMap {
          "\(firstName.wrappedValue) \(lastName.wrappedValue)"
        } onChange: { fullName in
          receivedValues.append(fullName)
          print("Full name: \(fullName)")
          confirm()
        }
      }

      // Initial value should be captured
      try? await Task.sleep(nanoseconds: 50_000_000)

      // Change first name
      Task {
        firstName.wrappedValue = "Jane"
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      // Change last name
      Task {
        lastName.wrappedValue = "Smith"
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      cancellable.cancel()
    }

    #expect(receivedValues == ["John Doe", "Jane Doe", "Jane Smith"])
  }

  @Test
  func distinctFilteringAutomatic() async throws {
    let value = Stored(wrappedValue: 10)

    var receivedValues: [Int] = []

    await confirmation(expectedCount: 3) { confirm in
      let cancellable = withGraphTracking {
        withGraphTrackingMap {
          value.wrappedValue
        } onChange: { val in
          receivedValues.append(val)
          print("Value: \(val)")
          confirm()
        }
      }

      try? await Task.sleep(nanoseconds: 50_000_000)

      // Change to different value
      Task {
        value.wrappedValue = 20
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      // Change to same value (should be filtered out - no confirmation call)
      Task {
        value.wrappedValue = 20
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      // Change to different value again
      Task {
        value.wrappedValue = 30
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      cancellable.cancel()
    }

    #expect(receivedValues == [10, 20, 30])
  }

  @Test
  func multipleNodeProjection() async throws {
    let x = Stored(wrappedValue: 1)
    let y = Stored(wrappedValue: 2)
    let z = Stored(wrappedValue: 3)  // Not accessed in projection

    var receivedSums: [Int] = []

    await confirmation(expectedCount: 3) { confirm in
      let cancellable = withGraphTracking {
        withGraphTrackingMap {
          x.wrappedValue + y.wrappedValue
        } onChange: { sum in
          receivedSums.append(sum)
          print("Sum: \(sum)")
          confirm()
        }
      }

      try? await Task.sleep(nanoseconds: 50_000_000)

      // Change x
      Task {
        x.wrappedValue = 5
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      // Change y
      Task {
        y.wrappedValue = 10
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      // Change z (not tracked, should not trigger - no confirmation call)
      Task {
        z.wrappedValue = 100
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      cancellable.cancel()
    }

    #expect(receivedSums == [3, 7, 15])
  }

  @Test
  func conditionalProjection() async throws {
    let useFullName = Stored(wrappedValue: true)
    let firstName = Stored(wrappedValue: "John")
    let lastName = Stored(wrappedValue: "Doe")
    let nickname = Stored(wrappedValue: "Johnny")

    var receivedNames: [String] = []

    await confirmation(expectedCount: 4) { confirm in
      let cancellable = withGraphTracking {
        withGraphTrackingMap {
          if useFullName.wrappedValue {
            return "\(firstName.wrappedValue) \(lastName.wrappedValue)"
          } else {
            return nickname.wrappedValue
          }
        } onChange: { name in
          receivedNames.append(name)
          print("Name: \(name)")
          confirm()
        }
      }

      try? await Task.sleep(nanoseconds: 50_000_000)

      // Change firstName (tracked)
      Task {
        firstName.wrappedValue = "Jane"
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      // Change nickname (not tracked when useFullName is true - no confirmation)
      Task {
        nickname.wrappedValue = "JJ"
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      // Switch to nickname mode
      Task {
        useFullName.wrappedValue = false
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      // Now nickname changes should be tracked
      Task {
        nickname.wrappedValue = "Jay"
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      // firstName changes should NOT trigger (not accessed anymore - no confirmation)
      Task {
        firstName.wrappedValue = "Bob"
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      cancellable.cancel()
    }

    #expect(receivedNames == ["John Doe", "Jane Doe", "JJ", "Jay"])
  }

  @Test
  func customFilter() async throws {
    struct ThresholdFilter: Filter {
      let threshold: Int
      private var lastValue: Int?

      init(threshold: Int) {
        self.threshold = threshold
        self.lastValue = nil
      }

      mutating func send(value: Int) -> Int? {
        guard let last = lastValue else {
          lastValue = value
          return value
        }
        if abs(value - last) >= threshold {
          lastValue = value
          return value
        }
        return nil
      }
    }

    let value = Stored(wrappedValue: 0)
    var receivedValues: [Int] = []

    await confirmation(expectedCount: 3) { confirm in
      let cancellable = withGraphTracking {
        withGraphTrackingMap(
          { value.wrappedValue },
          filter: ThresholdFilter(threshold: 5)
        ) { val in
          receivedValues.append(val)
          print("Significant change: \(val)")
          confirm()
        }
      }

      try? await Task.sleep(nanoseconds: 50_000_000)

      // Small change (< 5, should be filtered - no confirmation)
      Task {
        value.wrappedValue = 3
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      // Significant change (>= 5)
      Task {
        value.wrappedValue = 6
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      // Another small change (no confirmation)
      Task {
        value.wrappedValue = 8
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      // Another significant change
      Task {
        value.wrappedValue = 15
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      cancellable.cancel()
    }

    #expect(receivedValues == [0, 6, 15])
  }

  @Test
  func passthroughFilterAllowsDuplicates() async throws {
    let value = Stored(wrappedValue: 10)
    var receivedValues: [Int] = []

    // Note: Stored skips notification for same Equatable value,
    // so even with PassthroughFilter, same value won't trigger notification
    await confirmation(expectedCount: 2) { confirm in
      let cancellable = withGraphTracking {
        withGraphTrackingMap(
          { value.wrappedValue },
          filter: PassthroughFilter<Int>()
        ) { val in
          receivedValues.append(val)
          print("Value (passthrough): \(val)")
          confirm()
        }
      }

      try? await Task.sleep(nanoseconds: 50_000_000)

      // Change to different value
      Task {
        value.wrappedValue = 20
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      // Change to same value - Stored skips notification for Equatable types
      Task {
        value.wrappedValue = 20
      }
      try? await Task.sleep(nanoseconds: 100_000_000)

      cancellable.cancel()
    }

    #expect(receivedValues == [10, 20])
  }

  @Test
  @MainActor
  func skipsInitialCallback() async {
    let value = Stored(wrappedValue: 0)
    let didObserveChange = TestSignal()
    var receivedValues: [Int] = []

    let cancellable = withGraphTracking {
      withGraphTrackingMap(
        { value.wrappedValue },
        initial: false
      ) { value in
        receivedValues.append(value)
        didObserveChange.signal()
      }
    }
    defer { cancellable.cancel() }

    #expect(receivedValues.isEmpty)

    value.wrappedValue = 1

    #expect(await didObserveChange.wait(for: .seconds(5)))
    #expect(receivedValues == [1])
  }

  @Test
  @MainActor
  func skippingInitialCallbackSeedsCustomFilter() async {
    struct ThresholdFilter: Filter {
      let didProcessSmallChange: TestSignal
      private var lastValue: Int?

      mutating func send(value: Int) -> Int? {
        if value == 3 {
          didProcessSmallChange.signal()
        }

        guard let lastValue else {
          self.lastValue = value
          return value
        }

        guard abs(value - lastValue) >= 5 else {
          return nil
        }

        self.lastValue = value
        return value
      }
    }

    let value = Stored(wrappedValue: 0)
    let didProcessSmallChange = TestSignal()
    let didReceiveSignificantChange = TestSignal()
    var receivedValues: [Int] = []

    let cancellable = withGraphTracking {
      withGraphTrackingMap(
        { value.wrappedValue },
        filter: ThresholdFilter(didProcessSmallChange: didProcessSmallChange),
        initial: false
      ) { value in
        receivedValues.append(value)

        if value == 6 {
          didReceiveSignificantChange.signal()
        }
      }
    }
    defer { cancellable.cancel() }

    value.wrappedValue = 3

    #expect(await didProcessSmallChange.wait(for: .seconds(5)))
    #expect(receivedValues.isEmpty)

    value.wrappedValue = 6

    #expect(await didReceiveSignificantChange.wait(for: .seconds(5)))
    #expect(receivedValues == [6])
  }

  @Test
  @MainActor
  func dependencyMapsCanSkipInitialCallback() async {
    final class ViewModel {
      let value = Stored(wrappedValue: 0)
    }

    let viewModel = ViewModel()
    let didObserveChanges = TestCountdown(count: 2)
    var automaticallyFilteredValues: [Int] = []
    var customFilteredValues: [Int] = []

    let cancellable = withGraphTracking {
      withGraphTrackingMap(
        from: viewModel,
        map: { $0.value.wrappedValue },
        initial: false
      ) { value in
        automaticallyFilteredValues.append(value)
        didObserveChanges.signal()
      }

      withGraphTrackingMap(
        from: viewModel,
        map: { $0.value.wrappedValue },
        filter: PassthroughFilter(),
        initial: false
      ) { value in
        customFilteredValues.append(value)
        didObserveChanges.signal()
      }
    }
    defer { cancellable.cancel() }

    #expect(automaticallyFilteredValues.isEmpty)
    #expect(customFilteredValues.isEmpty)

    viewModel.value.wrappedValue = 1

    #expect(await didObserveChanges.wait(for: .seconds(5)))
    #expect(automaticallyFilteredValues == [1])
    #expect(customFilteredValues == [1])
  }

}
