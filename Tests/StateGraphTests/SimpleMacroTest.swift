import Testing
@testable import StateGraph

@Suite
struct SimpleMacroTest {
  
  @Test("Test simplified macro works")
  func testSimplifiedMacro() {
    struct TestModel {
      @GraphStored var count: Int = 0
    }
    
    let model = TestModel()
    #expect(model.count == 0)
    
    // Test that we can mutate the value
    // model.count = 10
    // #expect(model.count == 10)
  }
}