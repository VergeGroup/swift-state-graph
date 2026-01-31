
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

 ## Use Cases
 - Feature flags: Only track relevant nodes when features are enabled
 - UI state: Track different nodes based on current screen/mode
 - Performance optimization: Avoid expensive tracking when not needed
 - Dynamic dependency graphs: Build reactive systems that adapt to runtime conditions

 - Parameter handler: The closure to execute with conditional tracking
 - Parameter onTrace: Optional callback invoked after handler completes with all accessed nodes
 - Parameter isolation: Actor isolation context for execution
 */
public func withGraphTrackingGroup(
  _ handler: @escaping () -> Void,
  onTrace: (([any TypeErasedNode]) -> Void)? = nil,
  isolation: isolated (any Actor)? = #isolation
) {

  guard ThreadLocal.subscriptions.value != nil else {
    assertionFailure("You must call withGraphTracking before calling this method.")
    return
  }

  let _handlerBox = OSAllocatedUnfairLock<ClosureBox?>(
    uncheckedState: .init(handler: handler)
  )

  // onTrace が指定された場合はコレクターを使用
  let collector: NodeTraceCollector? = onTrace != nil ? NodeTraceCollector() : nil

  let executeWithTrace: () -> Void = {
    if let collector {
      ThreadLocal.traceCollector.withValue(collector) {
        _handlerBox.withLock { $0?.handler() }
      }
      // handler完了後にonTraceを呼び出し
      let tracedNodes = collector.drain()
      onTrace?(tracedNodes)
    } else {
      _handlerBox.withLock { $0?.handler() }
    }
  }

  withContinuousStateGraphTracking(
    apply: executeWithTrace,
    didChange: {
      guard !_handlerBox.withLock({ $0 == nil }) else { return .stop }
      return .next
    },
    isolation: isolation
  )

  let cancellable = AnyCancellable {
    _handlerBox.withLock { $0 = nil }
  }

  ThreadLocal.subscriptions.value!.append(cancellable)

}

private struct ClosureBox {
  let handler: () -> Void
  
  init(handler: @escaping () -> Void) {
    self.handler = handler
  }
}
