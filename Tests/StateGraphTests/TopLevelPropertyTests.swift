import Testing
@testable import StateGraph

// Top-level property test - this should not generate init accessors
@GraphStored
var topLevelValue1: Int = 42

@GraphStored
var topLevelValue2: Int = 42

@Suite
struct TopLevelPropertyTests {
  
  @Test func top_level_property_compilation() {
    // Test if top-level @GraphStored properties compile without init accessors
    print("Initial value: \(topLevelValue1)")
    
    topLevelValue1 = 100
    print("After setting to 100: \(topLevelValue1)")
    #expect(topLevelValue1 == 100)
    
    topLevelValue1 = 200
    print("After setting to 200: \(topLevelValue1)")
    #expect(topLevelValue1 == 200)
  }
  
  @Test func top_level_property_reactivity() async {
    // Reset value
    topLevelValue2 = 0
    
    await confirmation(expectedCount: 1) { c in
      let cancellable = withGraphTracking {
        $topLevelValue2.onChange { value in
          if value == 999 {
            c.confirm()
          }
        }
      }
      
      try? await Task.sleep(for: .milliseconds(10))
      
      topLevelValue2 = 999
      
      try? await Task.sleep(for: .milliseconds(10))
      
      withExtendedLifetime(cancellable, {})
    }
  }
}
