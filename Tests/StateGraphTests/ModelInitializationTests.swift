import SwiftUI
import Testing
import StateGraph

@Suite
struct ModModelInitializationTests {
  
  @Test func basic() {
    
    final class StateViewModel {
      
      @GraphStored
      var optional_variable: Int?
                  
      let shadow_value: Int
      
      init() {
        self.optional_variable = 0
        self.shadow_value = 0
        
      }
      
    }
    
    _ = StateViewModel()
  }
}
