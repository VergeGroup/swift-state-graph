
public protocol TypeErasedNode: Hashable, AnyObject, Sendable, CustomDebugStringConvertible {
  
  var name: String? { get }
  var info: NodeInfo { get }
  var lock: NodeLock { get }
  
  /// edges affecting nodes
  var outgoingEdges: ContiguousArray<Edge> { get set }
  
  /// inverse edges that depending on nodes
  var incomingEdges: ContiguousArray<Edge> { get set }
  
  @_spi(Internal)
  var trackingRegistrations: Set<TrackingRegistration> { get set }
  
  var potentiallyDirty: Bool { get set }
  
  func recomputeIfNeeded()
}

public protocol Node: TypeErasedNode {
  
  associatedtype Value
  
  var wrappedValue: Value { get }
  
}

extension Node {
  // MARK: Equatable
  public static func == (lhs: Self, rhs: Self) -> Bool {
    return lhs === rhs
  }
  
  // MARK: Hashable
  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
  
}

extension Node {
  
  public func map<ComputedValue>(
    _ project: @escaping @Sendable (Computed<ComputedValue>.Context, Self.Value) -> ComputedValue
  ) -> Computed<ComputedValue> {
    return Computed { context in
      project(context, self.wrappedValue)
    }
  }
  
}

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
