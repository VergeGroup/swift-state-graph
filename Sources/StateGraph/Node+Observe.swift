
// MARK: - StateGraph Node Observation
//
// This file provides reactive observation capabilities for StateGraph nodes.
// It includes:
// - AsyncSequence-based observation with `observe()`
// - Callback-based observation with `onChange()`  
// - Group tracking with `withGraphTrackingGroup()`
// - Value filtering with custom Filter implementations
//
// ## Quick Start Guide
//
// ### Basic Observation
// ```swift
// let node = Stored(wrappedValue: 0)
//
// // Method 1: Callback-based
// let cancellable = withGraphTracking {
//   node.onChange { value in
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
// // Filtered observations
// withGraphTracking {
//   // Only distinct values
//   node.onChange { value in /* Equitable values only */ }
//   
//   // Custom filtering
//   node.onChange(MyCustomFilter()) { value in /* filtered */ }
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
 
 This function establishes a reactive tracking context where you can subscribe to node changes
 using `onChange` methods or conditional tracking with `withGraphTrackingGroup`. All subscriptions
 created within this scope are automatically managed and cleaned up when the returned cancellable
 is cancelled or deallocated.
 
 ## Basic Usage
 ```swift
 let node = Stored(wrappedValue: 0)
 
 let cancellable = withGraphTracking {
   node.onChange { value in
     print("Value changed to: \(value)")
   }
 }
 
 // Later: cancel all subscriptions
 cancellable.cancel()
 ```
 
 ## Multiple Subscriptions
 ```swift
 let cancellable = withGraphTracking {
   node1.onChange { value in print("Node1: \(value)") }
   node2.onChange { value in print("Node2: \(value)") }
   node3.onChange { value in print("Node3: \(value)") }
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
  
  let subscriptions = Subscriptions.$subscriptions.withValue(.init()) {     
    scope()
    
    return Subscriptions.subscriptions!
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
  
  guard Subscriptions.subscriptions != nil else {
    assertionFailure("You must call withGraphTracking before calling this method.")
    return
  }
  
  let _handler = UnsafeSendable(handler)
      
  let isCancelled = OSAllocatedUnfairLock(initialState: false)
  
  withContinuousStateGraphTracking(
    apply: { 
      _handler._value()
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
  
  Subscriptions.subscriptions!.append(cancellabe)
  
}

/**
 A protocol for filtering values in node observation.

 Filters allow you to control which values trigger change notifications by implementing
 custom filtering logic. The filter's `send` method is called with each new value and
 can decide whether to pass it through or suppress the notification.
 */
public protocol Filter<Value> {

  associatedtype Value

  /// Processes a value and returns it if it should be passed to the handler, or nil to suppress the notification.
  /// - Parameter value: The new value from the node
  /// - Returns: The value to pass to the change handler, or nil to suppress
  ///   the handler call. Returning nil does NOT affect Observation notifications
  ///   (used by SwiftUI) - those are triggered at the node level when the node
  ///   becomes potentially dirty.
  mutating func send(value: Value) -> Value?
}

/**
 A filter that passes through all values without any filtering.

 This is the default filter used when no explicit filter is specified.
 Every value change will trigger the onChange handler.
 */
public struct PassthroughFilter<Value>: Filter {

  public func send(value: Value) -> Value? {
    return value
  }

  public init() {}
}

/**
 A filter that only passes through values that are different from the previous value.

 This filter uses equality comparison to suppress duplicate onChange handler calls,
 which is useful for avoiding unnecessary work when the actual value hasn't changed.

 Note: This only affects onChange handler calls. SwiftUI and other Observation
 consumers will still receive notifications when the node becomes potentially dirty,
 allowing them to check for updates. This is the correct behavior because:
 - SwiftUI needs to know a value *might* have changed to trigger re-evaluation
 - onChange handlers should only run when values *actually* changed

 ```swift
 node.onChange(DistinctFilter<String>()) { value in
   // Only called when value actually changes
   print("New value: \(value)")
 }
 ```
 */
public struct DistinctFilter<Value: Equatable>: Filter {

  private var lastValue: Value?

  public mutating func send(value: Value) -> Value? {
    guard value != lastValue else { return nil }
    lastValue = value
    return value
  }

  public init() {}
}

extension Node {
  
  /**
   Observes changes to this node's value with a custom filter.
   
   This method sets up a reactive subscription that calls the handler whenever the node's value
   changes, after applying the specified filter. The subscription is automatically managed
   within the current `withGraphTracking` scope.
   
   ## Filter Examples
   ```swift
   // Custom filter for significant changes only
   struct ThresholdFilter: Filter {
     let threshold: Double
     mutating func send(value: Double) -> Double {
       return abs(value) > threshold ? value : previousValue
     }
   }
   
   withGraphTracking {
     temperatureNode.onChange(ThresholdFilter(threshold: 5.0)) { temp in
       print("Significant temperature change: \(temp)")
     }
   }
   ```
   
   - Parameter filter: A filter to process values before triggering the handler
   - Parameter handler: Closure called when the filtered value changes
   - Parameter isolation: Actor isolation context for the handler execution
   
   - Important: Must be called within a `withGraphTracking` scope
   */
  public func onChange(
    _ filter: consuming some Filter<Self.Value>,
    _ handler: @escaping (Self.Value) -> Void,
    isolation: isolated (any Actor)? = #isolation
  ) {

    guard Subscriptions.subscriptions != nil else {
      assertionFailure("You must call withGraphTracking before calling onChange.")
      return
    }

    let _handler = UnsafeSendable(handler)
    var _filter = filter

    let isCancelled = OSAllocatedUnfairLock(initialState: false)

    withContinuousStateGraphTracking(
      apply: { [weak self] in
        _ = self?.wrappedValue
      },
      didChange: { [weak self] in
        guard let self else { return .stop }
        guard !isCancelled.withLock({ $0 }) else { return .stop }
        let filteredValue = _filter.send(value: self.wrappedValue)
        if let filteredValue = filteredValue {
          _handler._value(filteredValue)
        }
        return .next
      },
      isolation: isolation
    )

    // init
    let initialFilteredValue = _filter.send(value: self.wrappedValue)

    if let initialFilteredValue = initialFilteredValue {
      handler(initialFilteredValue)
    }

    let cancellabe = AnyCancellable {
      withExtendedLifetime(self) {}
      isCancelled.withLock { $0 = true }
    }

    Subscriptions.subscriptions!.append(cancellabe)

  }
  
  /**
   Observes all changes to this node's value.
   
   This is the most common way to observe node changes. Every value update will trigger
   the handler, regardless of whether the value is the same as the previous one.
   
   ```swift
   withGraphTracking {
     node.onChange { value in
       print("Node value: \(value)")
       updateUI(with: value)
     }
   }
   ```
   
   - Parameter handler: Closure called whenever the node's value changes
   - Parameter isolation: Actor isolation context for the handler execution
   
   - Important: Must be called within a `withGraphTracking` scope
   */
  public func onChange(
    _ handler: @escaping (Self.Value) -> Void,
    isolation: isolated (any Actor)? = #isolation
  ) {    
    onChange(PassthroughFilter<Self.Value>(), handler, isolation: isolation)
  }
  
  /**
   Observes changes to this node's value, but only when the value actually changes.
   
   This variant uses equality comparison to filter out duplicate notifications.
   It's particularly useful for expensive operations that should only run when
   the value is genuinely different.
   
   ```swift
   withGraphTracking {
     expensiveNode.onChange { value in
       // Only called when value != previous value
       performExpensiveOperation(with: value)
     }
   }
   ```
   
   - Parameter handler: Closure called when the node's value changes to a different value
   - Parameter isolation: Actor isolation context for the handler execution
   
   - Important: Must be called within a `withGraphTracking` scope
   - Note: Available only for `Equatable` value types
   */
  public func onChange(
    _ handler: @escaping (Self.Value) -> Void,
    isolation: isolated (any Actor)? = #isolation
  ) where Value : Equatable {
    onChange(DistinctFilter<Self.Value>(), handler, isolation: isolation)
  }
  
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
  
  @TaskLocal
  static var subscriptions: Subscriptions? = nil
}
