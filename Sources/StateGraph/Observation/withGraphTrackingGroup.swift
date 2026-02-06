
/**
 Group tracking for reactive processing within a graph tracking scope.
 
 This function enables Computed-like reactive processing where code is executed immediately
 and re-executed whenever any accessed nodes change. Unlike Computed nodes which return values,
 this executes side effects and operations based on node values, dynamically tracking only
 the nodes that are actually accessed during execution.
 
 ## Behavior
 - Must be called within a `withGraphTracking` scope
 - The handler closure is executed initially and re-executed whenever any tracked node changes
 - Only nodes accessed during execution are tracked for the next iteration
 - Nodes are dynamically added/removed from tracking based on runtime conditions
 
 ## Example: Group Tracking
 ```swift
 let condition = Stored(wrappedValue: 5)
 let conditionalNode = Stored(wrappedValue: 10) 
 let alwaysNode = Stored(wrappedValue: 20)
 
 withGraphTracking {
   withGraphTrackingGroup {
     // alwaysNode is always tracked
     print("Always: \(alwaysNode.wrappedValue)")
     
     // conditionalNode is only tracked when condition > 10
     if condition.wrappedValue > 10 {
       print("Conditional access: \(conditionalNode.wrappedValue)")
     }
   }
 }
 ```
 
 In this example:
 - `alwaysNode` changes will always trigger re-execution
 - `conditionalNode` changes only trigger re-execution when `condition > 10`
 - `condition` changes will trigger re-execution (to re-evaluate the condition)

 ## Nested Tracking

 Groups can be nested within each other. When a parent group re-executes, all nested children
 are automatically cancelled and recreated. This enables conditional nested tracking:

 ```swift
 let enableA = Stored(wrappedValue: true)
 let enableB = Stored(wrappedValue: false)
 let valueA = Stored(wrappedValue: 1)
 let valueB = Stored(wrappedValue: 2)

 withGraphTracking {
   withGraphTrackingGroup {
     // Conditionally create nested tracking based on feature flags
     if enableA.wrappedValue {
       withGraphTrackingGroup {
         print("Feature A: \(valueA.wrappedValue)")
       }
     }

     if enableB.wrappedValue {
       withGraphTrackingGroup {
         print("Feature B: \(valueB.wrappedValue)")
       }
     }
   }
 }
 ```

 In this example:
 - When `enableA` is true, changes to `valueA` trigger the nested group
 - When `enableA` becomes false, the nested group is destroyed (no longer tracking `valueA`)
 - When `enableA` becomes true again, a new nested group is created

 ## Use Cases
 - Feature flags: Only track relevant nodes when features are enabled
 - UI state: Track different nodes based on current screen/mode
 - Performance optimization: Avoid expensive tracking when not needed
 - Dynamic dependency graphs: Build reactive systems that adapt to runtime conditions
 - Conditional subscriptions: Create/destroy nested tracking based on runtime conditions

 - Parameter handler: The closure to execute with conditional tracking
 - Parameter isolation: Actor isolation context for execution
 */
public func withGraphTrackingGroup(
  file: StaticString = #fileID,
  line: UInt = #line,
  function: StaticString = #function,
  _ handler: @escaping () -> Void,
  isolation: isolated (any Actor)? = #isolation
) {

  let subscriptions = ThreadLocal.subscriptions.value
  let parentCancellable = ThreadLocal.currentCancellable.value

  // Either subscriptions (root level) or parentCancellable (nested level) must exist
  guard subscriptions != nil || parentCancellable != nil else {
    assertionFailure("You must call withGraphTracking before calling this method.")
    return
  }

  let _handlerBox = OSAllocatedUnfairLock<ClosureBox<Void>?>(
    uncheckedState: ClosureBox(handler)
  )

  // Create a cancellable for this scope that manages nested tracking
  let scopeCancellable = GraphTrackingCancellable { [file, line, function] in
    _handlerBox.withLock { $0 = nil }
  }

  withContinuousStateGraphTracking(
    file: file,
    line: line,
    function: function,
    apply: {
      // Cancel all children before re-executing (cleans up nested subscriptions)
      scopeCancellable.cancelChildren()

      // Set this scope's cancellable as the current parent for nested tracking
      // Nested groups/maps will register with this parent via addChild()
      ThreadLocal.currentCancellable.withValue(scopeCancellable) {
        _handlerBox.withLock {
          $0?()
        }
      }
    },
    didChange: {
      guard !_handlerBox.withLock({ $0 == nil }) else { return .stop }
      return .next
    },
    isolation: isolation
  )

  // Register with parent or root subscriptions
  if let parent = parentCancellable {
    parent.addChild(scopeCancellable)
  } else {
    subscriptions!.append(AnyCancellable(scopeCancellable))
  }

}
