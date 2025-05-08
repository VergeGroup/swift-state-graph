import Testing
@testable import StateGraph

@Suite("StoredNode.observe()")
struct NodeObserveTests {
  
  @Test
  func basic() async throws {
    let node = StoredNode(wrappedValue: 0)
    let stream = node.observe()
          
    try await confirmation(expectedCount: 2) { c in
      Task { 
        for try await _ in stream {
          c.confirm()
        }
      }
      node.wrappedValue = 1
      try await Task.sleep(nanoseconds: 100_000)
    }
    
  }
    
  @Test("Can observe value changes")
  func testObserveValueChanges() async throws {
    let node = StoredNode(wrappedValue: 0)
    let stream = node.observe()
    
    var results: [Int] = []
    let task = Task {
      for try await value in stream {
        print(value)
        results.append(value)
      }
    }
    
    try await Task.sleep(for: .milliseconds(100))
    
    // Initial value is included
    #expect(results == [0])
    
    // Change value
    node.wrappedValue = 1
    try await Task.sleep(for: .milliseconds(100))
    #expect(results == [0, 1])
    
    // Change value again
    node.wrappedValue = 2
    try await Task.sleep(for: .milliseconds(100))
    #expect(results == [0, 1, 2])
    
    // Even with the same value, change notification is sent
    node.wrappedValue = 2
    try await Task.sleep(for: .milliseconds(100))
    #expect(results == [0, 1, 2, 2])
    
    task.cancel()
  }
  
  @Test("Can observe complex type value changes")
  func testObserveWithComplexType() async throws {
    struct TestStruct: Equatable {
      var value: Int
    }
    
    let node = StoredNode(wrappedValue: TestStruct(value: 0))
    let stream = node.observe()
    
    var results: [TestStruct] = []
    let task = Task {
      for try await value in stream {
        results.append(value)
      }
    }
    
    try await Task.sleep(nanoseconds: 100_000)
    
    // Initial value is included
    #expect(results == [TestStruct(value: 0)])
    
    // Change value
    node.wrappedValue = TestStruct(value: 1)
    try await Task.sleep(nanoseconds: 100_000)
    #expect(results == [TestStruct(value: 0), TestStruct(value: 1)])
    
    // Change value again
    node.wrappedValue = TestStruct(value: 2)
    try await Task.sleep(nanoseconds: 100_000)
    #expect(results == [TestStruct(value: 0), TestStruct(value: 1), TestStruct(value: 2)])
    
    // Even with the same value, change notification is sent
    node.wrappedValue = TestStruct(value: 2)
    try await Task.sleep(nanoseconds: 100_000)
    #expect(results == [TestStruct(value: 0), TestStruct(value: 1), TestStruct(value: 2), TestStruct(value: 2)])
    
    task.cancel()
  }
  
  @Test("Multiple subscribers can exist simultaneously")
  func testObserveWithMultipleSubscribers() async throws {
    let node = StoredNode(wrappedValue: 0)
    
    var results1: [Int] = []
    var results2: [Int] = []
    
    let task1 = Task {
      for try await value in node.observe() {
        results1.append(value)
      }
    }
    
    let task2 = Task {
      for try await value in node.observe() {
        results2.append(value)
      }
    }
    
    try await Task.sleep(nanoseconds: 100_000)
    
    // Initial value is included
    #expect(results1 == [0])
    #expect(results2 == [0])
    
    // Change value
    node.wrappedValue = 1
    try await Task.sleep(nanoseconds: 100_000)
    #expect(results1 == [0, 1])
    #expect(results2 == [0, 1])
    
    // Change value again
    node.wrappedValue = 2
    try await Task.sleep(nanoseconds: 100_000)
    #expect(results1 == [0, 1, 2])
    #expect(results2 == [0, 1, 2])
    
    // Even with the same value, change notification is sent
    node.wrappedValue = 2
    try await Task.sleep(nanoseconds: 100_000)
    #expect(results1 == [0, 1, 2, 2])
    #expect(results2 == [0, 1, 2, 2])
    
    task1.cancel()
    task2.cancel()
  }
} 
