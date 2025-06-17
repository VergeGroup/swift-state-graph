import Testing
import StateGraph

/**
 this halts
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
    
    await node.wrappedValue.run()
    try! await Task.sleep(nanoseconds: 20_000_000) // 20ms between sends
    
    print(node.wrappedValue.value)
  }
  
}

*/
