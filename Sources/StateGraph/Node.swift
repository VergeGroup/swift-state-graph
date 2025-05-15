
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
  
  /**
    Create a computed value node that depends on this node.

    ```swift
    let computed = node.map { context, value in
      value * 2
    }
    ```
  */
  public func map<ComputedValue>(
    _ project: @escaping @Sendable (Computed<ComputedValue>.Context, Self.Value) -> ComputedValue
  ) -> Computed<ComputedValue> {
    return Computed { context in
      project(context, self.wrappedValue)
    }
  }
  
}
