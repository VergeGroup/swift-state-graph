import Testing
@testable import StateGraph

// Top-level property test - this should not generate init accessors
@GraphStored
var topLevelValue: Int = 42

@Suite
struct TopLevelPropertyTests {
  
  @Test func top_level_property_compilation() {
    // Test if top-level @GraphStored properties compile without init accessors
    print("Initial value: \(topLevelValue)")
    
    topLevelValue = 100
    print("After setting to 100: \(topLevelValue)")
    #expect(topLevelValue == 100)
    
    topLevelValue = 200
    print("After setting to 200: \(topLevelValue)")
    #expect(topLevelValue == 200)
  }
  
  @Test func top_level_property_reactivity() async {
    // Reset value
    topLevelValue = 0
    
    await confirmation(expectedCount: 1) { c in
      let cancellable = withGraphTracking {
        $topLevelValue.onChange { value in
          if value == 999 {
            c.confirm()
          }
        }
      }
      
      try? await Task.sleep(for: .milliseconds(10))
      
      topLevelValue = 999
      
      try? await Task.sleep(for: .milliseconds(10))
      
      withExtendedLifetime(cancellable, {})
    }
  }
}