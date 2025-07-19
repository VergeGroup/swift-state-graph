import Testing
import StateGraph
import Foundation

@Suite("Deadlock Tests")
struct DeadlockTests {
  
  final class NotificationCounter: @unchecked Sendable {
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
  
  struct State {
    
    var value: Int = 0
    
    mutating func run() async {
      try! await Task.sleep(nanoseconds: 100_000_000) // 100ms
    }
    
    mutating func updateValueDuringAsync() async {
      value = 1
      try! await Task.sleep(nanoseconds: 50_000_000) // 50ms
      value = 2
      try! await Task.sleep(nanoseconds: 50_000_000) // 50ms
      value = 3
    }
  }
  
  @Test
  func deadlockDetectionWithMultipleObjects() async {
    
    let node = Stored<State>.init(wrappedValue: .init())
    
    // Test that direct property access with async operations doesn't deadlock
    // This would have caused deadlock with the old _modify implementation     
    // https://github.com/VergeGroup/swift-state-graph/pull/56
    await node.wrappedValue.run()
    try! await Task.sleep(nanoseconds: 20_000_000) // 20ms between sends
    
    print(node.wrappedValue.value)
  }
  
  @Test
  func notificationCountDuringMutatingAsync() async {
    let node = Stored<State>.init(wrappedValue: .init())
    
    let counter = NotificationCounter()
    let computed = Computed { _ in 
      counter.increment()
      return node.wrappedValue.value
    }
    
    // Initial access to establish dependency
    _ = computed.wrappedValue
    #expect(counter.count == 1)
    
    // Reset counter
    counter.reset()
    
    // Test: Direct property assignment pattern (getter + setter)
    print("=== Testing getter/setter pattern ===")
    await node.wrappedValue.updateValueDuringAsync()  // mutating async operation
    
    // Check how many notifications were triggered
    _ = computed.wrappedValue  // Force recomputation to get final count
    print("Notifications after getter/setter pattern: \(counter.count)")
    #expect(counter.count == 1)  // Should be 1 notification from setter
    #expect(node.wrappedValue.value == 3)
  }
  
  @Test 
  func notificationCountWithMultipleDirectAssignments() async {
    let node = Stored<State>.init(wrappedValue: .init())
    
    let counter = NotificationCounter()
    let computed = Computed { _ in 
      counter.increment()
      return node.wrappedValue.value
    }
    
    // Initial access
    _ = computed.wrappedValue
    #expect(counter.count == 1)
    counter.reset()
    
    print("=== Testing multiple direct assignments ===")
    
    // Multiple direct assignments
    print("Before first assignment, counter: \(counter.count)")
    node.wrappedValue = State(value: 1)
    print("After first assignment, counter: \(counter.count)")
    
    node.wrappedValue = State(value: 2)
    print("After second assignment, counter: \(counter.count)")
    
    node.wrappedValue = State(value: 3)
    print("After third assignment, counter: \(counter.count)")
    
    // Check notifications
    print("Before final computed access, counter: \(counter.count)")
    _ = computed.wrappedValue
    print("Notifications after 3 direct assignments: \(counter.count)")
    
    // Update expectation based on actual behavior
    print("Actual behavior: Only 1 notification triggered when computed value is accessed")
    #expect(counter.count == 1)  // Computed is lazily evaluated only once
    #expect(node.wrappedValue.value == 3)
  }
  
  @Test
  func immediateNotificationBehavior() async {
    let node = Stored<State>.init(wrappedValue: .init())
    
    let counter = NotificationCounter()
    let computed = Computed { _ in 
      counter.increment()
      return node.wrappedValue.value
    }
    
    // Establish dependency
    _ = computed.wrappedValue
    counter.reset()
    
    print("=== Testing immediate notification behavior ===")
    
    // Assignment followed by immediate access
    print("Counter before assignment: \(counter.count)")
    node.wrappedValue = State(value: 1)
    print("Counter after assignment, before access: \(counter.count)")
    _ = computed.wrappedValue
    print("Counter after computed access: \(counter.count)")
    
    counter.reset()
    
    // Multiple assignments with intermittent access
    node.wrappedValue = State(value: 2)
    _ = computed.wrappedValue  // Access 1
    print("After assignment & access 1: \(counter.count)")
    
    node.wrappedValue = State(value: 3)  
    _ = computed.wrappedValue  // Access 2
    print("After assignment & access 2: \(counter.count)")
    
    #expect(counter.count == 2)  // Two separate computations
    #expect(node.wrappedValue.value == 3)
  }
  
}
