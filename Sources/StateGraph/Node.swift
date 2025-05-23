/// A type-erased interface for nodes participating in the state graph.
public protocol TypeErasedNode: Hashable, AnyObject, Sendable, CustomDebugStringConvertible {
  // var name: String? { get }

  /// Metadata about the node such as its identifier and source location.
  var info: NodeInfo { get }

  /// Lock protecting mutations on the node.
  var lock: NodeLock { get }

  /// Edges pointing to nodes affected by this node.
  var outgoingEdges: ContiguousArray<Edge> { get set }

  /// Edges pointing from nodes this node depends on.
  var incomingEdges: ContiguousArray<Edge> { get set }

  /// Registrations used when tracking state changes.
  @_spi(Internal)
  var trackingRegistrations: Set<TrackingRegistration> { get set }

  /// Indicates whether the node requires recomputation.
  var potentiallyDirty: Bool { get set }

  /// Performs recomputation if the node is dirty.
  func recomputeIfNeeded()
}

/// A node producing a value of type ``Value``.
public protocol Node: TypeErasedNode {

  /// The type of value the node produces.
  associatedtype Value

  /// Accesses the node's value, recomputing if necessary.
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
