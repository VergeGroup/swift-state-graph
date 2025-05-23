
extension Node {
  
  /// Returns an asynchronous stream emitting the current value followed by subsequent updates.
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
  /// Prepends a value to the sequence before any asynchronous values are emitted.
  func startWith(_ value: Element) -> AsyncStartWithSequence<Self> {
    return AsyncStartWithSequence(self, startWith: value)
  }
}

/// A sequence that yields an initial value before forwarding to its base sequence.
public struct AsyncStartWithSequence<Base: AsyncSequence>: AsyncSequence {
  
  public struct AsyncIterator: AsyncIteratorProtocol {
    /// The sequence element type.
    public typealias Element = Base.Element

    /// Iterator of the underlying sequence.
    private var base: Base.AsyncIterator

    /// The first element to yield.
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
  
  /// The sequence element type.
  public typealias Element = Base.Element

  /// The underlying sequence.
  let base: Base

  /// The element to yield before any from ``base``.
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
/// Executes ``scope`` while registering any node accesses and returns a cancellable token.
public func withGraphTracking(_ scope: () -> Void) -> AnyCancellable {
  
  let subscriptions = Subscriptions.$subscriptions.withValue(.init()) {     
    scope()
    
    return Subscriptions.subscriptions!
  }
  
  return AnyCancellable {
    withExtendedLifetime(subscriptions) {}
  }
  
}

/// A filter that can transform or drop values before they are forwarded to a handler.
public protocol Filter<Value> {
  
  associatedtype Value
    
  mutating func send(value: Value) -> Value
}

/// A ``Filter`` that forwards values unchanged.
public struct PassthroughFilter<Value>: Filter {
  
  public func send(value: Value) -> Value {
    return value
  }
  
  public init() {}
}

/// A ``Filter`` that only forwards values when they differ from the previous value.
public struct DistinctFilter<Value: Equatable>: Filter {
  
  /// Last forwarded value used to detect duplicates.
  private var lastValue: Value?
  
  public mutating func send(value: Value) -> Value {
    guard value != lastValue else { return value }
    lastValue = value
    return value
  }
  
  public init() {}
}

extension Node {
  
  /// Registers a handler that is called when the node's value changes.
  /// - Parameters:
  ///   - filter: Filter used to preprocess values before they are sent.
  ///   - handler: Closure invoked with the (filtered) value.
  ///   - isolation: Actor on which the handler should run.
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
  
  /// Registers a handler called for every value change.
  public func onChange(
    _ handler: @escaping (Self.Value) -> Void,
    isolation: isolated (any Actor)? = #isolation
  ) {
    onChange(PassthroughFilter<Self.Value>(), handler, isolation: isolation)
  }
  
  /// Registers a handler that is only called when the value actually changes.
  public func onChange(
    _ handler: @escaping (Self.Value) -> Void,
    isolation: isolated (any Actor)? = #isolation
  ) where Value : Equatable {
    onChange(DistinctFilter<Self.Value>(), handler, isolation: isolation)
  }
  
}

// MARK: - Internals

@_exported @preconcurrency import class Combine.AnyCancellable

/// A container for ``AnyCancellable`` instances used during tracking scopes.
final class Subscriptions: Sendable, Hashable {
  
  static func == (lhs: Subscriptions, rhs: Subscriptions) -> Bool {
    lhs === rhs
  }
  
  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
  
  /// Stored cancellables protected by a lock.
  let cancellables = OSAllocatedUnfairLock<[AnyCancellable]>(initialState: [])
  
  init() {
    
  }  
  
  func append(_ cancellable: AnyCancellable) {
    cancellables.withLock {
      $0.append(cancellable)
    }
  }
  
  /// Task-local storage for the current subscriptions container.
  @TaskLocal
  static var subscriptions: Subscriptions? = nil
}
