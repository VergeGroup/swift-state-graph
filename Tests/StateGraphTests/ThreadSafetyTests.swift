import XCTest
#if canImport(os.lock)
import os.lock
#endif

@testable import StateGraph

final class ThreadSafetyTests: XCTestCase {

  func testConcurrentDynamicDependencyChange() async throws {
    let toggle = Stored(name: "toggle", wrappedValue: false)
    let a = Stored(name: "a", wrappedValue: 0)
    let b = Stored(name: "b", wrappedValue: 0)

    let computed = Computed(name: "computed") { _ in
      toggle.wrappedValue ? a.wrappedValue : b.wrappedValue
    }

    await withTaskGroup(of: Void.self) { group in
      for i in 0..<200 {
        group.addTask {
          if i % 3 == 0 {
            toggle.wrappedValue.toggle()
          } else if i % 3 == 1 {
            a.wrappedValue += 1
          } else {
            b.wrappedValue += 1
          }
          _ = computed.wrappedValue
        }
      }
    }

    let expected = toggle.wrappedValue ? a.wrappedValue : b.wrappedValue
    XCTAssertEqual(computed.wrappedValue, expected)
  }

  func testMassiveParallelGraphUpdates() async throws {
    let sources = (0..<20).map { Stored(name: "s\($0)", wrappedValue: 0) }
    let computed = Computed(name: "sum") { _ in
      sources.reduce(0) { $0 + $1.wrappedValue }
    }

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<1000 {
        group.addTask {
          let idx = Int.random(in: 0..<sources.count)
          sources[idx].wrappedValue += 1
          if Bool.random() {
            _ = computed.wrappedValue
          }
        }
      }
    }

    let expectedSum = sources.reduce(0) { $0 + $1.wrappedValue }
    XCTAssertEqual(computed.wrappedValue, expectedSum)
  }
}
