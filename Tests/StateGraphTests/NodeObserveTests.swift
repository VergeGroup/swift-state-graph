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
    
    // Even with the same value, change notification is sent
    node.wrappedValue = 2
    try await Task.sleep(for: .milliseconds(100))
    #expect(results.withLock { $0 == [0, 1, 2, 2] })
    
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
    
    // Even with the same value, change notification is sent
    node.wrappedValue = TestStruct(value: 2)
    try await Task.sleep(for: .milliseconds(100))
    
    #expect(results.withLock { $0 == [TestStruct(value: 0), TestStruct(value: 1), TestStruct(value: 2), TestStruct(value: 2)] })
    
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
    
    // Even with the same value, change notification is sent
    node.wrappedValue = 2
    try await Task.sleep(for: .milliseconds(100))
    #expect(results1.withLock { $0 == [0, 1, 2, 2] })
    #expect(results2.withLock { $0 == [0, 1, 2, 2] })
    
    task1.cancel()
    task2.cancel()
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
