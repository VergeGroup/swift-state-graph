import Testing
@testable import StateGraph

@Suite("Stored.observe()")
struct NodeObserveTests {

  @Test
  func basic() async throws {
    let node = Stored(wrappedValue: 0)
    let stream = node.observe()

    await confirmation(expectedCount: 2) { c in
      Task {
        for try await _ in stream {
          c.confirm()
        }
      }
      node.wrappedValue = 1

      try? await Task.sleep(for: .milliseconds(100))

    }

  }

  @Test("Can observe value changes")
  func testObserveValueChanges() async throws {
    let node = Stored(wrappedValue: 0)
    let stream = node.observe()

    let results = OSAllocatedUnfairLock.init(initialState: [Int]())
    let task = Task {
      for try await value in stream {
        print(value)
        results.withLock { $0.append(value) }
      }
    }

    try await Task.sleep(for: .milliseconds(100))

    // Initial value is included
    #expect(results.withLock { $0 == [0] })


    // Change value
    node.wrappedValue = 1
    try await Task.sleep(for: .milliseconds(100))
    #expect(results.withLock { $0 == [0, 1] })

    // Change value again
    node.wrappedValue = 2
    try await Task.sleep(for: .milliseconds(100))
    #expect(results.withLock { $0 == [0, 1, 2] })

    // Same value should NOT trigger notification (Equatable optimization)
    node.wrappedValue = 2
    try await Task.sleep(for: .milliseconds(100))
    #expect(results.withLock { $0 == [0, 1, 2] })

    task.cancel()
  }

  @Test("Can observe complex type value changes")
  func testObserveWithComplexType() async throws {
    struct TestStruct: Equatable {
      var value: Int
    }

    let node = Stored(wrappedValue: TestStruct(value: 0))
    let stream = node.observe()

    let results = OSAllocatedUnfairLock.init(initialState: [TestStruct]())
    let task = Task {
      for try await value in stream {
        results.withLock { $0.append(value) }
      }
    }
    try await Task.sleep(for: .milliseconds(100))

    // Initial value is included
    #expect(results.withLock { $0 == [TestStruct(value: 0)] })

    // Change value
    node.wrappedValue = TestStruct(value: 1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(results.withLock { $0 == [TestStruct(value: 0), TestStruct(value: 1)] })

    // Change value again
    node.wrappedValue = TestStruct(value: 2)
    try await Task.sleep(for: .milliseconds(100))
    #expect(results.withLock { $0 == [TestStruct(value: 0), TestStruct(value: 1), TestStruct(value: 2)] })

    // Same value should NOT trigger notification (Equatable optimization)
    node.wrappedValue = TestStruct(value: 2)
    try await Task.sleep(for: .milliseconds(100))
    #expect(results.withLock { $0 == [TestStruct(value: 0), TestStruct(value: 1), TestStruct(value: 2)] })

    task.cancel()
  }

  @Test("Multiple subscribers can exist simultaneously")
  func testObserveWithMultipleSubscribers() async throws {
    let node = Stored(wrappedValue: 0)

    let results1 = OSAllocatedUnfairLock.init(initialState: [Int]())
    let results2 = OSAllocatedUnfairLock.init(initialState: [Int]())

    let task1 = Task {
      for try await value in node.observe() {
        results1.withLock { $0.append(value) }
      }
    }

    let task2 = Task {
      for try await value in node.observe() {
        results2.withLock { $0.append(value) }
      }
    }

    try await Task.sleep(for: .milliseconds(100))

    // Initial value is included
    #expect(results1.withLock { $0 == [0] })
    #expect(results2.withLock { $0 == [0] })

    // Change value
    node.wrappedValue = 1
    try await Task.sleep(for: .milliseconds(100))
    #expect(results1.withLock { $0 == [0, 1] })
    #expect(results2.withLock { $0 == [0, 1] })

    // Change value again
    node.wrappedValue = 2
    try await Task.sleep(for: .milliseconds(100))
    #expect(results1.withLock { $0 == [0, 1, 2] })
    #expect(results2.withLock { $0 == [0, 1, 2] })

    // Same value should NOT trigger notification (Equatable optimization)
    node.wrappedValue = 2
    try await Task.sleep(for: .milliseconds(100))
    #expect(results1.withLock { $0 == [0, 1, 2] })
    #expect(results2.withLock { $0 == [0, 1, 2] })

    task1.cancel()
    task2.cancel()
  }

  @Test("Non-Equatable types always notify on assignment")
  func testNonEquatableAlwaysNotifies() async throws {
    // Non-Equatable struct
    struct NonEquatableStruct: Sendable {
      var value: Int
    }

    let node = Stored(wrappedValue: NonEquatableStruct(value: 0))
    let stream = node.observe()

    let results = OSAllocatedUnfairLock.init(initialState: [Int]())
    let task = Task {
      for try await value in stream {
        results.withLock { $0.append(value.value) }
      }
    }

    try await Task.sleep(for: .milliseconds(100))

    // Initial value
    #expect(results.withLock { $0 == [0] })

    // Change value
    node.wrappedValue = NonEquatableStruct(value: 1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(results.withLock { $0 == [0, 1] })

    // Same value - but non-Equatable always notifies
    node.wrappedValue = NonEquatableStruct(value: 1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(results.withLock { $0 == [0, 1, 1] })

    task.cancel()
  }

  @Test("Reference types skip notification for same reference")
  func testReferenceTypesSameReference() async throws {
    final class RefType: @unchecked Sendable {
      var value: Int
      init(value: Int) { self.value = value }
    }

    let obj = RefType(value: 0)
    let node = Stored(wrappedValue: obj)
    let stream = node.observe()

    let results = OSAllocatedUnfairLock.init(initialState: [Int]())
    let task = Task {
      for try await value in stream {
        results.withLock { $0.append(value.value) }
      }
    }

    try await Task.sleep(for: .milliseconds(100))

    // Initial value included
    #expect(results.withLock { $0 == [0] })

    // Different reference - should notify
    let obj2 = RefType(value: 1)
    node.wrappedValue = obj2
    try await Task.sleep(for: .milliseconds(100))
    #expect(results.withLock { $0 == [0, 1] })

    // Same reference - should NOT notify
    node.wrappedValue = obj2
    try await Task.sleep(for: .milliseconds(100))
    #expect(results.withLock { $0 == [0, 1] })

    task.cancel()
  }

  @Test("Equatable reference types use value equality")
  func testEquatableReferenceTypes() async throws {
    final class EquatableRefType: Equatable, @unchecked Sendable {
      var value: Int
      init(value: Int) { self.value = value }
      static func == (lhs: EquatableRefType, rhs: EquatableRefType) -> Bool {
        lhs.value == rhs.value
      }
    }

    let obj1 = EquatableRefType(value: 0)
    let node = Stored(wrappedValue: obj1)
    let stream = node.observe()

    let results = OSAllocatedUnfairLock.init(initialState: [Int]())
    let task = Task {
      for try await value in stream {
        results.withLock { $0.append(value.value) }
      }
    }

    try await Task.sleep(for: .milliseconds(100))

    // Initial value included
    #expect(results.withLock { $0 == [0] })

    // Different reference but equal value - should NOT notify
    let obj2 = EquatableRefType(value: 0)
    node.wrappedValue = obj2
    try await Task.sleep(for: .milliseconds(100))
    #expect(results.withLock { $0 == [0] })

    // Different value - should notify
    let obj3 = EquatableRefType(value: 1)
    node.wrappedValue = obj3
    try await Task.sleep(for: .milliseconds(100))
    #expect(results.withLock { $0 == [0, 1] })

    task.cancel()
  }

}
