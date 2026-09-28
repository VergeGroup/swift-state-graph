/// Every per-thread slot StateGraph uses, in one place.
///
/// Each slot owns one process-lifetime key that is never deleted, and musl and
/// Bionic allow only 128 keys per process, so this list is also the key budget.
///
/// Declare new slots here rather than next to their users. The slot primitives
/// live in `Threading/`.
enum ThreadLocal: Sendable {

  // MARK: Scoped: installed and restored around a synchronous scope.

  static let registration: ThreadLocalValue<TrackingRegistration> = .init()
  static let subscriptions: ThreadLocalValue<Subscriptions> = .init()
  static let currentNode: ThreadLocalValue<any TypeErasedNode> = .init()
  static let currentCancellable: ThreadLocalValue<GraphTrackingCancellable> = .init()
  static let graphTransaction: ThreadLocalValue<GraphTransactionContext> = .init()
  static let graphTransactionReadScope: ThreadLocalValue<GraphTransactionReadScope> = .init()
  static let graphImmediateWriterScope: ThreadLocalValue<GraphImmediateWriterScope> = .init()
  static let storedInitializationScope: ThreadLocalValue<StoredInitializationScope> = .init()
#if DEBUG
  static let graphMutationProhibition: ThreadLocalValue<GraphMutationProhibition> = .init()
#endif

  // MARK: Thread lifetime: created on first use, destroyed at thread exit.

  /// The Observation key paths handed out to nodes created on this thread.
  static let nodeObservationKeyPaths: ThreadLocalState<NodeObservationKeyPathTable> = .init {
    NodeObservationKeyPathTable()
  }

}
