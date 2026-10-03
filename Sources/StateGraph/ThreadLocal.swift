/// Every per-thread slot StateGraph uses, in one place.
///
/// Each slot owns one process-lifetime key that is never deleted, and musl and
/// Bionic allow only 128 keys per process, so this list is also the key budget.
/// The key-path table in `KeyPath.swift` still creates one key of its own and is
/// not listed here yet.
///
/// Declare new slots here rather than next to their users. The slot primitives
/// live in `Threading/`.
enum ThreadLocal: Sendable {

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

}
