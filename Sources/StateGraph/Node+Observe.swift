
extension Node {
  
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
  func startWith(_ value: Element) -> AsyncStartWithSequence<Self> {
    return AsyncStartWithSequence(self, startWith: value)
  }
}

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
  Start observing the changes of the node's value.
  Stored and Computed nodes have `onChange` method.
  You can call this method inside `withGraphTracking` scope.

  ```swift
  let cancellable = withGraphTracking {
    node.onChange { value in
      print("Value changed to: \(value)")
    }
  }
  ```
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
 Conditional dependency tracking within a graph tracking scope.
 
 This function enables dynamic dependency management where nodes are only tracked
 when they are accessed within true conditional branches. This allows for efficient
 resource usage by avoiding unnecessary subscriptions.
 
 ## Behavior
 - Must be called within a `withGraphTracking` scope
 - The handler closure is executed initially and re-executed whenever any tracked node changes
 - Only nodes accessed during execution are tracked for the next iteration
 - Conditional nodes are dynamically added/removed from tracking based on runtime conditions
 
 ## Example: Conditional Tracking
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
       print("Conditional: \(conditionalNode.wrappedValue)")
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

public protocol Filter<Value> {
  
  associatedtype Value
    
  mutating func send(value: Value) -> Value
}

public struct PassthroughFilter<Value>: Filter {
  
  public func send(value: Value) -> Value {
    return value
  }
  
  public init() {}
}

public struct DistinctFilter<Value: Equatable>: Filter {
  
  private var lastValue: Value?
  
  public mutating func send(value: Value) -> Value {
    guard value != lastValue else { return value }
    lastValue = value
    return value
  }
  
  public init() {}
}

extension Node {
  
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
        
    let isCancelled = OSAllocatedUnfairLock(initialState: false)
    
    withContinuousStateGraphTracking(
      apply: { [weak self] in
        _ = self?.wrappedValue
      },
      didChange: { [weak self] in
        guard let self else { return .stop }
        guard !isCancelled.withLock({ $0 }) else { return .stop }        
        _handler._value(filter.send(value: self.wrappedValue))
        return .next
      },
      isolation: isolation
    ) 
                  
    // init    
    handler(filter.send(value: self.wrappedValue))
    
    let cancellabe = AnyCancellable {
      withExtendedLifetime(self) {}
      isCancelled.withLock { $0 = true }     
    }
    
    Subscriptions.subscriptions!.append(cancellabe)
          
  }
  
  public func onChange(
    _ handler: @escaping (Self.Value) -> Void,
    isolation: isolated (any Actor)? = #isolation
  ) {    
    onChange(PassthroughFilter<Self.Value>(), handler, isolation: isolation)
  }
  
  /**
   Emits the value only when it changes.
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
