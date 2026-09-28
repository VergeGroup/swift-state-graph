import Testing
@testable import StateGraph

@Suite
struct StaticPropertyTests {
  
  final class ModelWithStatic {
    @GraphStored
    static var sharedValue: Int = 0

    // Written only by `static_property_reactivity`. Tests in this suite run concurrently,
    // so sharing `sharedValue` would let another test's writes land while that test
    // awaits a projection.
    @GraphStored
    static var observedValue: Int = 0

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
    // Reset the value left by an earlier repetition.
    ModelWithStatic.observedValue = 0

    let observedTen = TestSignal()
    let observedFortyTwo = TestSignal()

    await confirmation(expectedCount: 2) { c in
      // The initial projection runs synchronously, so tracking is established before
      // the first write.
      let cancellable = withGraphTracking {
        withGraphTrackingMap {
          ModelWithStatic.$observedValue.wrappedValue
        } onChange: { value in
          if value == 10 {
            c.confirm()
            observedTen.signal()
          } else if value == 42 {
            c.confirm()
            observedFortyTwo.signal()
          }
        }
      }

      // Re-projection is asynchronous. Awaiting each delivery keeps the next write from
      // coalescing with the previous one.
      ModelWithStatic.observedValue = 10
      #expect(await observedTen.wait(for: .seconds(5)))

      ModelWithStatic.observedValue = 42
      #expect(await observedFortyTwo.wait(for: .seconds(5)))

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
