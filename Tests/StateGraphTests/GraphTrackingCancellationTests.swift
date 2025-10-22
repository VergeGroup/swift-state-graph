import Foundation
import Testing

@testable import StateGraph

@Suite("GraphTrackingCancellation Tests")
struct GraphTrackingCancellationTests {
  
  final class Resource {
    deinit {
      
    }
  }
  
  @Test
  func resourceReleasing() {
    
    let node = Stored(wrappedValue: 0)
    
    let pointer = Unmanaged.passRetained(Resource())
    
    weak var resourceRef: Resource? = pointer.takeUnretainedValue()
            
    let subscription = withGraphTracking {
      withGraphTrackingGroup { [resource = pointer.takeUnretainedValue()] in
        print(node.wrappedValue)
        print(resource)
      }
    }
    
    pointer.release()  
    
    #expect(resourceRef != nil)
    
    subscription.cancel()
    
    #expect(resourceRef == nil)
        
  }
  
}
