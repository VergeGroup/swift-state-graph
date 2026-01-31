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

@Suite("Stored.onDidSet()")
struct StoredDidSetTests {

  @Test("didSet is called on value change")
  func testDidSetCalledOnValueChange() {
    let node = Stored(wrappedValue: 0)
    var captured: (Int, Int)?

    node.onDidSet { old, new in
      captured = (old, new)
    }

    node.wrappedValue = 42

    #expect(captured?.0 == 0)
    #expect(captured?.1 == 42)
  }

  @Test("didSet is called for multiple changes")
  func testDidSetMultipleChanges() {
    let node = Stored(wrappedValue: "initial")
    var history: [(String, String)] = []

    node.onDidSet { old, new in
      history.append((old, new))
    }

    node.wrappedValue = "second"
    node.wrappedValue = "third"

    #expect(history.count == 2)
    #expect(history[0].0 == "initial")
    #expect(history[0].1 == "second")
    #expect(history[1].0 == "second")
    #expect(history[1].1 == "third")
  }

  @Test("didSet is called even when value is the same")
  func testDidSetCalledForSameValue() {
    let node = Stored(wrappedValue: 10)
    var callCount = 0

    node.onDidSet { _, _ in
      callCount += 1
    }

    node.wrappedValue = 10
    node.wrappedValue = 10

    #expect(callCount == 2)
  }

  @Test("didSet handler can be replaced")
  func testDidSetHandlerReplacement() {
    let node = Stored(wrappedValue: 0)
    var firstHandlerCalled = false
    var secondHandlerCalled = false

    node.onDidSet { _, _ in
      firstHandlerCalled = true
    }

    node.onDidSet { _, _ in
      secondHandlerCalled = true
    }

    node.wrappedValue = 1

    #expect(firstHandlerCalled == false)
    #expect(secondHandlerCalled == true)
  }

}
