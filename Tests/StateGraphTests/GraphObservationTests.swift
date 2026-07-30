import Foundation
import Testing

@testable import StateGraph

@Suite("GraphObservation Tests")
struct GraphObservationTests {

  final class ValueCollector<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [T] = []

    var values: [T] {
      lock.lock()
      defer { lock.unlock() }
      return _values
    }

    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return _values.count
    }

    func append(_ value: T) {
      lock.lock()
      defer { lock.unlock() }
      _values.append(value)
    }
  }

  @Test
  func basicAsyncSequence() async throws {
    let firstName = Stored(wrappedValue: "John")
    let lastName = Stored(wrappedValue: "Doe")
    let collector = ValueCollector<String>()

    let task = Task {
      for await fullName in GraphObservation({
        "\(firstName.wrappedValue) \(lastName.wrappedValue)"
      }) {
        collector.append(fullName)
        if collector.count >= 3 {
          break
        }
      }
    }

    try await Task.sleep(nanoseconds: 50_000_000)

    firstName.wrappedValue = "Jane"
    try await Task.sleep(nanoseconds: 100_000_000)

    lastName.wrappedValue = "Smith"
    try await Task.sleep(nanoseconds: 100_000_000)

    await task.value

    #expect(collector.values == ["John Doe", "Jane Doe", "Jane Smith"])
  }

  @Test
  func startWithBehavior() async throws {
    let value = Stored(wrappedValue: 42)
    let collector = ValueCollector<Int>()

    let task = Task {
      for await v in GraphObservation({ value.wrappedValue }) {
        collector.append(v)
        break
      }
    }

    await task.value

    #expect(collector.values == [42])
  }

  @Test
  func dynamicTracking() async throws {
    let useA = Stored(wrappedValue: true)
    let valueA = Stored(wrappedValue: "A")
    let valueB = Stored(wrappedValue: "B")
    let collector = ValueCollector<String>()

    let task = Task {
      for await v in GraphObservation({
        useA.wrappedValue ? valueA.wrappedValue : valueB.wrappedValue
      }) {
        collector.append(v)
        if collector.count >= 3 {
          break
        }
      }
    }

    try await Task.sleep(nanoseconds: 50_000_000)

    // Change valueB (not tracked when useA is true)
    valueB.wrappedValue = "B2"
    try await Task.sleep(nanoseconds: 100_000_000)

    // Switch to B
    useA.wrappedValue = false
    try await Task.sleep(nanoseconds: 100_000_000)

    // Now valueB is tracked
    valueB.wrappedValue = "B3"
    try await Task.sleep(nanoseconds: 100_000_000)

    await task.value

    #expect(collector.values == ["A", "B2", "B3"])
  }

  @Test
  func taskCancellation() async throws {
    let value = Stored(wrappedValue: 0)
    let collector = ValueCollector<Int>()

    let task = Task {
      for await v in GraphObservation({ value.wrappedValue }) {
        collector.append(v)
      }
    }

    try await Task.sleep(nanoseconds: 50_000_000)

    value.wrappedValue = 1
    try await Task.sleep(nanoseconds: 100_000_000)

    task.cancel()
    try await Task.sleep(nanoseconds: 50_000_000)

    value.wrappedValue = 2
    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(collector.count <= 2)
  }

  @Test
  func untilFinished() async throws {
    let iterationCounter = Stored(wrappedValue: 0)
    let value = Stored(wrappedValue: 0)
    let collector = ValueCollector<Int>()

    let task = Task {
      for await v in GraphObservation<Int>.untilFinished({
        iterationCounter.wrappedValue += 1
        if iterationCounter.wrappedValue > 3 {
          return .finish
        }
        return .next(value.wrappedValue)
      }) {
        collector.append(v)
      }
    }

    try await Task.sleep(nanoseconds: 50_000_000)

    value.wrappedValue = 10
    try await Task.sleep(nanoseconds: 100_000_000)

    value.wrappedValue = 20
    try await Task.sleep(nanoseconds: 100_000_000)

    value.wrappedValue = 30
    try await Task.sleep(nanoseconds: 100_000_000)

    await task.value

    #expect(collector.values == [0, 10, 20])
  }

  @Test
  func multipleNodes() async throws {
    let x = Stored(wrappedValue: 1)
    let y = Stored(wrappedValue: 2)
    let z = Stored(wrappedValue: 3)
    let collector = ValueCollector<Int>()

    let task = Task {
      for await sum in GraphObservation({ x.wrappedValue + y.wrappedValue }) {
        collector.append(sum)
        if collector.count >= 3 {
          break
        }
      }
    }

    try await Task.sleep(nanoseconds: 50_000_000)

    x.wrappedValue = 5
    try await Task.sleep(nanoseconds: 100_000_000)

    // Change z (not tracked)
    z.wrappedValue = 100
    try await Task.sleep(nanoseconds: 50_000_000)

    y.wrappedValue = 10
    try await Task.sleep(nanoseconds: 100_000_000)

    await task.value

    #expect(collector.values == [3, 7, 15])
  }
}
