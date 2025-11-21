
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
