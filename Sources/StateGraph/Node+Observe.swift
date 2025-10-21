
// MARK: - StateGraph Node Observation
//
// This file provides reactive observation capabilities for StateGraph nodes.
// It includes:
// - AsyncSequence-based observation with `observe()`
// - Projected value tracking with `withGraphTrackingMap()`
// - Group tracking with `withGraphTrackingGroup()`
// - Value filtering with custom Filter implementations
//
// ## Quick Start Guide
//
// ### Basic Observation
// ```swift
// let node = Stored(wrappedValue: 0)
//
// // Method 1: Projected value tracking
// let cancellable = withGraphTracking {
//   withGraphTrackingMap {
//     node.wrappedValue
//   } onChange: { value in
//     print("Changed to: \(value)")
//   }
// }
//
// // Method 2: AsyncSequence-based
// for try await value in node.observe() {
//   print("Value: \(value)")
// }
// ```
//
// ### Advanced Patterns
// ```swift
// // Group tracking - reactive processing
// withGraphTracking {
//   withGraphTrackingGroup {
//     if featureFlag.wrappedValue {
//       performExpensiveOperation(expensiveNode.wrappedValue)
//     }
//     updateUI(alwaysTrackedNode.wrappedValue)
//   }
// }
//
// // Projected value tracking with custom filtering
// withGraphTracking {
//   withGraphTrackingMap(
//     { node.wrappedValue },
//     filter: MyCustomFilter()
//   ) { value in
//     print("Filtered value: \(value)")
//   }
// }
// ```

extension Node {
  
  /**
   Creates an async sequence that emits the node's value whenever it changes.
   
   This method provides an AsyncSequence-based API for observing node changes, which integrates
   well with Swift's async/await concurrency model. The sequence starts by emitting the current
   value, then emits subsequent values as the node changes.
   
   ## Basic Usage
   ```swift
   let node = Stored(wrappedValue: 0)
   
   for try await value in node.observe() {
     print("Value: \(value)")
     // Handle the value...
   }
   ```
   
   ## With Async Processing
   ```swift
   Task {
     for try await value in node.observe() {
       await processValue(value)
     }
   }
   ```
   
   ## Finite Processing
   ```swift
   let stream = node.observe()
   var iterator = stream.makeAsyncIterator()
   
   let initialValue = try await iterator.next()
   let nextValue = try await iterator.next()
   ```
   
   - Returns: An async sequence that emits the node's value on changes
   - Note: The sequence starts with the current value, then emits subsequent changes
   - Note: The sequence continues indefinitely until cancelled or the node is deallocated
   */
  public func observe() -> AsyncStartWithSequence<AsyncMapSequence<AsyncStream<Void>, Self.Value>> {
    
    let stream = withStateGraphTrackingStream {
      _ = self.wrappedValue
    }
      .map { 
        self.wrappedValue
      }
      .startWith(self.wrappedValue)
    
    return stream
  }
  
}

extension AsyncSequence {
  /// Creates a new async sequence that starts by emitting the given value before the base sequence.
  func startWith(_ value: Element) -> AsyncStartWithSequence<Self> {
    return AsyncStartWithSequence(self, startWith: value)
  }
}

/**
 An async sequence that emits an initial value before proceeding with the base sequence.
 
 This is used internally by `Node.observe()` to ensure that the current value is emitted
 immediately, followed by subsequent changes from the base tracking stream.
 */
public struct AsyncStartWithSequence<Base: AsyncSequence>: AsyncSequence {
  
  public struct AsyncIterator: AsyncIteratorProtocol {
    public typealias Element = Base.Element
    
    private var base: Base.AsyncIterator
    private var first: Base.Element?
    
    init(_ value: Base.AsyncIterator, startWith: Base.Element) {
      self.base = value
      self.first = startWith
    }
    
    public mutating func next() async throws -> Base.Element? {
      if let first = first {
        self.first = nil
        return first
      }
      return try await base.next()
    }
  }
  
  public typealias Element = Base.Element
  
  let base: Base
  let startWith: Base.Element
  
  init(_ base: Base, startWith: Base.Element) {
    self.base = base
    self.startWith = startWith
  }
  
  public func makeAsyncIterator() -> AsyncIterator {
    return AsyncIterator(base.makeAsyncIterator(), startWith: startWith)
  }
}

extension AsyncStartWithSequence: Sendable where Base.Element: Sendable, Base: Sendable {}

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
 - Parameter isolation: Actor isolation context for execution
 */
public func withGraphTrackingGroup(
  _ handler: @escaping () -> Void,
  isolation: isolated (any Actor)? = #isolation
) {

  guard ThreadLocal.subscriptions.value != nil else {
    assertionFailure("You must call withGraphTracking before calling this method.")
    return
  }
        
  let isCancelled = OSAllocatedUnfairLock(initialState: false)
  
  withContinuousStateGraphTracking(
    apply: {
      handler()
    },
    didChange: {
      guard !isCancelled.withLock({ $0 }) else { return .stop }
      return .next
    },
    isolation: isolation
  )

  let cancellabe = AnyCancellable {
    isCancelled.withLock { $0 = true }
  }

  ThreadLocal.subscriptions.value!.append(cancellabe)
  
}

/**
 Tracks graph nodes accessed during projection and calls onChange when filtered values change.

 This function enables reactive processing where you project (compute) a derived value from
 multiple nodes, and receive change notifications only for distinct values. It's similar to
 `withGraphTrackingGroup`, but adds value projection and filtering capabilities.

 ## Behavior
 - Must be called within a `withGraphTracking` scope
 - The `applier` closure is executed initially and re-executed whenever any accessed nodes change
 - Only nodes accessed during `applier` execution are tracked
 - The projected value is passed through a `DistinctFilter` (for `Equatable` types)
 - `onChange` is only called when the filtered value passes through (i.e., when it's different)

 ## Example: Computed Value Tracking
 ```swift
 let firstName = Stored(wrappedValue: "John")
 let lastName = Stored(wrappedValue: "Doe")
 let age = Stored(wrappedValue: 30)

 withGraphTracking {
   // Track full name changes, ignore age changes
   withGraphTrackingMap {
     "\(firstName.wrappedValue) \(lastName.wrappedValue)"
   } onChange: { fullName in
     print("Name changed to: \(fullName)")  // Only called when name actually changes
   }
 }

 firstName.wrappedValue = "Jane"  // ✓ Triggers: "Jane Doe"
 lastName.wrappedValue = "Smith"  // ✓ Triggers: "Jane Smith"
 age.wrappedValue = 31            // ✗ Doesn't trigger (age not accessed in applier)
 firstName.wrappedValue = "Jane"  // ✗ Doesn't trigger (same value, filtered by DistinctFilter)
 ```

 ## Use Cases
 - Derived state tracking: Monitor computed values from multiple nodes
 - UI state calculation: Compute view states from multiple data sources
 - Performance optimization: Only update when computed values actually change
 - Conditional dependencies: Dynamically track different nodes based on conditions

 - Parameter applier: Closure that computes the projected value by accessing nodes
 - Parameter onChange: Handler called with the filtered projected value
 - Parameter isolation: Actor isolation context for execution

 - Important: This variant automatically uses `DistinctFilter`, only triggering for distinct values
 */
public func withGraphTrackingMap<Projection>(
  _ applier: @escaping () -> Projection,
  onChange: @escaping (Projection) -> Void,
  isolation: isolated (any Actor)? = #isolation
) where Projection : Equatable {
  withGraphTrackingMap(applier, filter: DistinctFilter(), onChange: onChange)
}

/**
 Tracks graph nodes accessed during projection with custom filtering.

 This is the fully customizable variant of `withGraphTrackingMap` that allows you to specify
 a custom filter for controlling when `onChange` is triggered. This is useful when you need
 filtering logic beyond simple equality comparison.

 ## Custom Filter Example
 ```swift
 // Only notify on significant percentage changes
 struct SignificantChangeFilter: Filter {
   private var lastValue: Double?
   private let threshold: Double = 0.1  // 10% change

   mutating func send(value: Double) -> Double? {
     guard let last = lastValue else {
       lastValue = value
       return value
     }
     let change = abs((value - last) / last)
     if change >= threshold {
       lastValue = value
       return value
     }
     return nil
   }
 }

 let progress = Stored(wrappedValue: 0.0)

 withGraphTracking {
   withGraphTrackingMap(
     { progress.wrappedValue },
     filter: SignificantChangeFilter()
   ) { value in
     print("Significant progress change: \(value)")
   }
 }

 progress.wrappedValue = 0.05  // ✗ Not significant (< 10%)
 progress.wrappedValue = 0.15  // ✓ Significant (>= 10%)
 ```

 ## Advanced Use Case: Debouncing
 ```swift
 struct DebounceFilter<Value>: Filter {
   private var lastTime: Date?
   private let interval: TimeInterval

   mutating func send(value: Value) -> Value? {
     let now = Date()
     if let last = lastTime, now.timeIntervalSince(last) < interval {
       return nil  // Suppress rapid changes
     }
     lastTime = now
     return value
   }
 }
 ```

 - Parameter applier: Closure that computes the projected value by accessing nodes
 - Parameter filter: Custom filter to control when onChange is triggered
 - Parameter onChange: Handler called with the filtered projected value
 - Parameter isolation: Actor isolation context for execution
 */
public func withGraphTrackingMap<Projection>(
  _ applier: @escaping () -> Projection,
  filter: consuming some Filter<Projection>,
  onChange: @escaping (Projection) -> Void,
  isolation: isolated (any Actor)? = #isolation
) {

  guard ThreadLocal.subscriptions.value != nil else {
    assertionFailure("You must call withGraphTracking before calling this method.")
    return
  }
  
  let isCancelled = OSAllocatedUnfairLock(initialState: false)
  
  var filter = filter
    
  withContinuousStateGraphTracking(
    apply: { 
      let result = applier()
      let filtered = filter.send(value: result)
      if let filtered {
        onChange(filtered)
      }
    },
    didChange: {
      guard !isCancelled.withLock({ $0 }) else { return .stop }        
      return .next
    },
    isolation: isolation
  )
  
  let cancellabe = AnyCancellable {
    isCancelled.withLock { $0 = true }
  }

  ThreadLocal.subscriptions.value!.append(cancellabe)

}


// MARK: - Internals

@_exported @preconcurrency import class Combine.AnyCancellable

final class Subscriptions: Sendable, Hashable {
  
  static func == (lhs: Subscriptions, rhs: Subscriptions) -> Bool {
    lhs === rhs
  }
  
  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
  
  let cancellables = OSAllocatedUnfairLock<[AnyCancellable]>(initialState: [])
  
  init() {
    
  }  
  
  func append(_ cancellable: AnyCancellable) {
    cancellables.withLock {
      $0.append(cancellable)
    }
  }

}
