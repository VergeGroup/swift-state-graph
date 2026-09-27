import Foundation

/// The `Computed` evaluations whose node locks the current thread holds, together with
/// release work that must wait until the outermost of them unlocks.
///
/// Evaluation nests node locks from downstream to upstream: a `Computed` keeps its lock
/// while it refreshes and reads its sources. Deinitializing a node reaches neighbors in
/// the opposite direction as well. It invalidates each downstream node and, for a
/// released `Computed`, detaches each upstream edge. Descriptor temporaries and
/// replaced cached values run that deinitialization while evaluation locks are held.
/// Locking a node that this thread owns would trap because `NodeLock` is nonrecursive,
/// and waiting for a node that another thread owns could deadlock with that thread's
/// evaluation.
///
/// A release observed during an evaluation therefore never waits for a node lock:
///
/// - A downstream node evaluating on this thread keeps the pending edge. A refresh
///   consumes it before recomputing; a descriptor already read that source.
/// - Any other downstream node becomes dirty if its lock is free. Its Observation and
///   graph-tracking callbacks run after the outermost evaluation unlocks.
/// - A contended downstream node, and every upstream edge detachment, waits for that
///   same point.
final class ComputedEvaluationStack {

  private enum DeferredWork {
    /// Removes a released `Computed` node's dependency edge from its source.
    case detachSource(Edge)
    /// Invalidates the edge's target unless it has consumed the edge by recomputing.
    case invalidateTarget(Edge)
    /// Delivers callbacks captured when an evaluation-time release dirtied a node.
    case deliver(() -> Void)
  }

  /// Nodes whose lock this thread holds for evaluation, outermost first.
  private var evaluatingNodes: ContiguousArray<ObjectIdentifier> = []

  private var deferredWork: [DeferredWork] = []

  private init() {
  }

  // MARK: - Thread-Local Storage

  /// The key under which each thread keeps its stack until it exits.
  ///
  /// This does not use `ThreadLocalValue`, which models values that graph operations
  /// install and restore around a scope. A thread creates its stack on its first
  /// evaluation and reuses it for its lifetime, and every deinitializing node with edges
  /// reads it.
  private static let key: pthread_key_t = {
    var key = pthread_key_t()
    let result = pthread_key_create(&key) { stack in
      Unmanaged<ComputedEvaluationStack>.fromOpaque(stack).release()
    }
    precondition(result == 0, "StateGraph could not allocate its evaluation thread-local key.")
    return key
  }()

  /// The current thread's stack, or `nil` if the thread has not evaluated a node.
  private static var current: ComputedEvaluationStack? {
    guard let stack = pthread_getspecific(key) else { return nil }
    return Unmanaged<ComputedEvaluationStack>.fromOpaque(stack).takeUnretainedValue()
  }

  // MARK: - Evaluation

  /// Records that the current thread holds `node`'s lock while evaluating it.
  ///
  /// Call this after acquiring the node lock and before any work that can release a node.
  static func beginEvaluation(of node: some TypeErasedNode) -> ComputedEvaluationStack {
    let stack: ComputedEvaluationStack
    if let current {
      stack = current
    } else {
      stack = ComputedEvaluationStack()
      let result = pthread_setspecific(key, Unmanaged.passRetained(stack).toOpaque())
      precondition(result == 0, "StateGraph could not store its evaluation thread-local state.")
    }

    stack.evaluatingNodes.append(ObjectIdentifier(node))
    return stack
  }

  /// Ends the innermost evaluation and releases its node lock.
  ///
  /// When this was the thread's outermost evaluation, the thread no longer holds an
  /// evaluation lock, so deferred release work runs here. That work may wait for other
  /// node locks or invoke callbacks that read the graph again.
  func endEvaluation(of node: some TypeErasedNode, unlocking lock: NodeLock) {
    let evaluatedNode = evaluatingNodes.removeLast()
    assert(evaluatedNode == ObjectIdentifier(node), "Computed evaluations must end in LIFO order.")

    guard evaluatingNodes.isEmpty, !deferredWork.isEmpty else {
      lock.unlock()
      return
    }

    // Callbacks below may evaluate again and defer work of their own.
    let work = deferredWork
    deferredWork.removeAll()
    lock.unlock()

    // The outermost read may belong to a tracking pass. These invalidations come from
    // releases rather than from that pass, so it must neither suppress them as its own
    // nor register the reads made by synchronous Observation callbacks.
    ThreadLocal.registration.withValue(nil) {
      for item in work {
        switch item {
        case .detachSource(let edge):
          edge.from?.removeOutgoingEdge(edge)
        case .invalidateTarget(let edge):
          guard let target = edge.to else { break }
          Self.releaseInvalidatableNode(target).invalidateUnlessConsumed(edge)
        case .deliver(let callbacks):
          callbacks()
        }
      }
    }
  }

  // MARK: - Release

  /// Publishes a deinitializing node's removal to the nodes connected by its edges.
  ///
  /// - Parameters:
  ///   - incomingEdges: A released `Computed` node's dependency edges. Their sources
  ///     still list them as outgoing edges.
  ///   - outgoingEdges: Edges to the nodes that read the released node.
  static func publishRelease(
    incomingEdges: ContiguousArray<Edge>,
    outgoingEdges: ContiguousArray<Edge>
  ) {
    guard let stack = current, !stack.evaluatingNodes.isEmpty else {
      // This thread holds no evaluation lock, so it may wait for any node.
      for edge in incomingEdges {
        edge.from?.removeOutgoingEdge(edge)
      }

      for edge in outgoingEdges {
        edge.to?.sourceDidRelease(edge)
      }
      return
    }

    for edge in incomingEdges {
      stack.deferredWork.append(.detachSource(edge))
    }

    for edge in outgoingEdges {
      // The pending tombstone only takes the edge's leaf lock. Keep it before any
      // dirty state so a refresh or a later read recomputes without this source.
      edge.isPending = true
      stack.invalidateTarget(of: edge)
    }
  }

  /// Marks the target of `edge` dirty without waiting for a node lock.
  ///
  /// A target evaluating on this thread is left to that evaluation, matching the
  /// no-op effect of dirtying a node whose refresh is already in progress.
  func invalidateTarget(of edge: Edge) {
    guard let target = edge.to else { return }
    guard !evaluatingNodes.contains(ObjectIdentifier(target)) else { return }

    if !Self.releaseInvalidatableNode(target).invalidateWithoutWaiting(during: self) {
      deferredWork.append(.invalidateTarget(edge))
    }
  }

  /// Returns a dependency target's release invalidation support.
  ///
  /// Only `Computed` nodes record incoming edges, so every edge target conforms.
  private static func releaseInvalidatableNode(
    _ target: any TypeErasedNode
  ) -> any EvaluationReleaseInvalidatableNode {
    guard let target = target as? any EvaluationReleaseInvalidatableNode else {
      preconditionFailure(
        "A node release reached a dependency node without evaluation-time invalidation support."
      )
    }
    return target
  }

  /// Delivers callbacks after the thread's outermost evaluation unlocks.
  func deferDelivery(_ callbacks: @escaping () -> Void) {
    deferredWork.append(.deliver(callbacks))
  }
}

/// A dependency target that a release during evaluation can dirty without blocking.
protocol EvaluationReleaseInvalidatableNode: AnyObject {

  /// Marks this node dirty if its lock is free, deferring its callbacks to `evaluation`.
  ///
  /// Dirty state propagates through the same stack so no downstream lock is awaited.
  ///
  /// - Returns: `false` if this node's lock is held. The caller must defer the
  ///   invalidation instead of waiting.
  func invalidateWithoutWaiting(during evaluation: ComputedEvaluationStack) -> Bool

  /// Marks this node dirty unless it has consumed `edge` by recomputing.
  ///
  /// Runs a deferred invalidation after the releasing thread's outermost evaluation
  /// unlocks, so it may wait for this node's lock.
  func invalidateUnlessConsumed(_ edge: Edge)
}
