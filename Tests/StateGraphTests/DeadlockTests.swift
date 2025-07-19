import Testing
import StateGraph

@Suite("Deadlock Tests")
struct DeadlockTests {
  
  struct State {
    
    var value: Int = 0
    
    mutating func run() async {
      try! await Task.sleep(nanoseconds: 100_000_000) // 100ms
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
  
}
