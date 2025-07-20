import Testing
@testable import StateGraph

@Suite
struct StaticPropertyTests {
  
  final class ModelWithStatic {
    @GraphStored
    static var sharedValue: Int = 0
    
    @GraphStored
    var instanceValue: Int = 0
  }
    
  @Test @MainActor func static_property_compilation() {
    // Test if static @GraphStored properties compile and work correctly
    ModelWithStatic.sharedValue = 10
    #expect(ModelWithStatic.sharedValue == 10)
    
    ModelWithStatic.sharedValue = 20
    #expect(ModelWithStatic.sharedValue == 20)
    
    // Test instance property still works
    let instance = ModelWithStatic()
    instance.instanceValue = 5
    #expect(instance.instanceValue == 5)
  }
  
  @Test @MainActor func static_property_reactivity() async {
    // Reset static value
    ModelWithStatic.sharedValue = 0
    
    await confirmation(expectedCount: 2) { c in
      let cancellable = withGraphTracking {
        ModelWithStatic.$sharedValue.onChange { value in
          if value == 10 {
            c.confirm()
          } else if value == 42 {
            c.confirm()
          }
        }
      }
      
      // Wait a bit before changing values
      try? await Task.sleep(for: .milliseconds(10))
      
      ModelWithStatic.sharedValue = 10
      
      try? await Task.sleep(for: .milliseconds(10))
      
      ModelWithStatic.sharedValue = 42
      
      try? await Task.sleep(for: .milliseconds(10))
      
      withExtendedLifetime(cancellable, {})
    }
  }
  
  // TODO: @GraphComputed doesn't support static properties yet
  // This test is commented out until that functionality is added
  /*
  @Test func static_property_computed_dependency() {
    final class ModelWithComputedStatic {
      @GraphStored
      static var baseValue: Int = 10
      
      @GraphComputed
      static var doubledValue: Int
      
      static func initialize() {
        Self.$doubledValue = .init { _ in
          Self.baseValue * 2
        }
      }
    }
    
    ModelWithComputedStatic.initialize()
    
    #expect(ModelWithComputedStatic.doubledValue == 20)
    
    ModelWithComputedStatic.baseValue = 15
    #expect(ModelWithComputedStatic.doubledValue == 30)
  }
  */
}
