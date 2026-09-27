public protocol TypeErasedNode: Hashable, AnyObject, Sendable, CustomDebugStringConvertible {
  // var name: String? { get }
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

extension TypeErasedNode {

  /// Returns an independent snapshot of the node's outgoing dependency edges.
  func outgoingEdgesSnapshot() -> ContiguousArray<Edge> {
    lock.lock()
    defer { lock.unlock() }
    return outgoingEdges
  }

  /// Removes an outgoing edge while holding the owning node's lock.
  func removeOutgoingEdge(_ edge: Edge) {
    lock.lock()
    outgoingEdges.removeAll(where: { $0 === edge })
    lock.unlock()
  }

  /// Publishes the release of an incoming edge's source to its target.
  ///
  /// The target retains the detached edge as a pending tombstone until its next
  /// read. This matters even when the source had no pending value change because
  /// a weak source read may switch to a fallback when the source disappears.
  func sourceDidRelease(_ edge: Edge) {
    edge.isPending = true
    potentiallyDirty = true
  }
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
  public func map<ComputedValue: SendableMetatype>(
    _ project: @escaping @Sendable (Computed<ComputedValue>.Context, Self.Value) -> ComputedValue
  ) -> Computed<ComputedValue> {
    return Computed { context in
      project(context, self.wrappedValue)
    }
  }
  
}
