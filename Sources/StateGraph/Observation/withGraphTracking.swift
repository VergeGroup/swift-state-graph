
/**
 Creates a tracking scope for observing node changes in the StateGraph.

 This function establishes a reactive tracking context where you can use `withGraphTrackingMap`,
 `withGraphTrackingGroup`, or other tracking functions. All subscriptions created within this
 scope are automatically managed and cleaned up when the returned cancellable is cancelled or
 deallocated.

 ## Basic Usage
 ```swift
 let node = Stored(wrappedValue: 0)

 let cancellable = withGraphTracking {
   withGraphTrackingMap {
     node.wrappedValue
   } onChange: { value in
     print("Value changed to: \(value)")
   }
 }

 // Later: cancel all subscriptions
 cancellable.cancel()
 ```

 ## Multiple Subscriptions
 ```swift
 let cancellable = withGraphTracking {
   withGraphTrackingMap { node1.wrappedValue } onChange: { print("Node1: \($0)") }
   withGraphTrackingMap { node2.wrappedValue } onChange: { print("Node2: \($0)") }
   withGraphTrackingMap { node3.wrappedValue } onChange: { print("Node3: \($0)") }
 }
 // All subscriptions are managed together
 ```

 ## Group Tracking
 ```swift
 let cancellable = withGraphTracking {
   withGraphTrackingGroup {
     if condition.wrappedValue {
       performOperation(conditionalNode.wrappedValue)
     }
     updateUI(alwaysNode.wrappedValue)
   }
 }
 ```

 ## Memory Management
 - The returned `AnyCancellable` manages all subscriptions created within the scope
 - Subscriptions are automatically cancelled when the cancellable is deallocated
 - Use `cancellable.cancel()` for explicit cleanup

 - Parameter scope: A closure where you set up your node observations
 - Returns: An `AnyCancellable` that manages all subscriptions created within the scope
 */
public func withGraphTracking(_ scope: () -> Void) -> AnyCancellable {

  let subscriptions = ThreadLocal.subscriptions.withValue(.init()) {
    scope()

    return ThreadLocal.subscriptions.value!
  }
  
  return AnyCancellable {
    withExtendedLifetime(subscriptions) {}
  }
  
}
