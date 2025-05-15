
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
    withExtendedLifetime(subscriptions) { 
      
    }
  }
  
}

public protocol Filter {
  
  associatedtype Value
    
  func send(value: Value) -> Value
}

public struct PassthroughFilter<Value>: Filter {
  
  public func send(value: Value) -> Value {
    return value
  }
  
  public init() {}
}

extension Node {
  
  public func onChange(
    _ filter: some Filter = PassthroughFilter<Value>(),
    _ handler: @escaping (Self.Value) -> Void
  ) {
    
    guard Subscriptions.subscriptions != nil else {
      assertionFailure("You must call withGraphTracking before calling onChange.")
      return
    }
    
    let isCancelled = OSAllocatedUnfairLock(initialState: false)
    
    withContinuousStateGraphTracking { 
      _ = self.wrappedValue
    } didChange: {       
      handler(self.wrappedValue)
      return .next
    }

    // init    
    handler(self.wrappedValue)
    
    let cancellabe = AnyCancellable {
      isCancelled.withLock { $0 = true }     
    }
    
    Subscriptions.subscriptions!.append(cancellabe)
          
  }
  
}

// MARK: - Internals

@preconcurrency import Combine

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
