import SwiftUI
import Testing
import StateGraph

@Suite
struct ModelInitializationTests {
  
  @Test func basic() {
    
    final class StateViewModel {
      
      @GraphStored
      var optional_variable: Int?
                  
      let shadow_value: Int
      
      init() {
        self.shadow_value = 0
        self.optional_variable = 0
      }
      
    }
    
    _ = StateViewModel()
  }
}
