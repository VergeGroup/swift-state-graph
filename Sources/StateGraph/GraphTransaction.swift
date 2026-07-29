import Foundation

/// Runs synchronous `Stored` mutations as one graph transaction.
///
/// The outermost call creates a transaction context. Assignments to ``Stored`` nodes
/// are staged in node-local buffers, so reads made by `body` observe their latest
/// staged values while other threads continue to observe the previously committed
/// graph. At commit, StateGraph snapshots affected Observation nodes after current
/// readers finish, then invokes the existing `willSet` delivery path before
/// publication. A synchronously delivered handler on the committing thread can
/// read the complete staged snapshot while other threads still read the old
/// committed graph. The staged values are then committed together before
/// graph-tracking and `onDidSet(_:)` callbacks are delivered.
///
/// A callback mutation joins a following commit batch owned by the same outer
/// transaction. Its staged value is immediately readable by later callbacks on the
/// committing thread, and the batch is published before this function returns.
/// Every batch uses each `Stored` node's ordinary comparator and callback pipeline.
///
/// Nested calls join the active transaction. They do not create a savepoint or an
/// independent commit or rollback boundary: if an inner error is caught by `body`,
/// its staged assignments remain part of the outer transaction. Only an error that
/// leaves the outermost call rolls all staged assignments back.
///
/// This API is synchronous and nonescaping. Its dynamic context is thread-local;
/// do not assume it is preserved across `await`, task creation, or executor hops.
/// While an outer transaction body is running, writes from other threads wait until
/// it completes. Those threads may continue reading committed values. During the
/// short commit phase, reads wait so they cannot observe a partially committed set
/// of nodes.
///
/// `Computed` values read by the transaction or its synchronous callbacks are
/// evaluated from staged values without updating the committed cache or dependency
/// graph. The next ordinary read continues to use the committed graph.
///
/// - Important: Rollback applies to `Stored` assignments only. Mutating properties
///   through reference storage reachable from a `Stored` value is an external side
///   effect and cannot be rolled back. This includes a class instance stored directly
///   or as an entity in a value-semantic collection. Mutating `GraphUserDefault`,
///   databases, or other externally committed sources inside `body` is unsupported;
///   their persistence, locking, and rollback semantics are outside this API.
/// - Important: ``Stored/unsafeModify(_:)`` deliberately bypasses assignment,
///   invalidation, and transaction staging. A mutation made through it is not
///   rolled back.
/// - Important: Synchronous callbacks run before the outer call returns and while
///   writes from other threads remain suspended. Reentrant `Stored` assignments are
///   supported, but a comparator or callback must not synchronously wait for another
///   thread to complete a graph write. Callbacks that existing APIs schedule
///   asynchronously do not inherit the thread-local transaction.
///   This includes Observation delivery that uses StateGraph's existing MainActor
///   hop: after a hop, the handler reads the coherent committed snapshot current
///   when it runs rather than transaction-local staged storage.
/// - Important: An ordinary immediate assignment evaluates `Stored`'s
///   `shouldNotify` closure and synchronously delivered Observation `willSet`
///   handlers while a node lock is held. Do not begin a transaction there or from
///   ``Stored/unsafeModify(_:)``; use `onDidSet(_:)` or another post-mutation
///   callback instead. Transaction commit evaluates comparators and delivers its
///   Observation callbacks outside node locks, but comparators should remain free
///   of mutation side effects.
/// - Important: Keep committed ``Computed`` descriptors free of graph mutations.
///   A descriptor owns its node's evaluation lock, so beginning a transaction, or
///   blocking on one through a `Stored` assignment, would create a lock-order cycle.
///   StateGraph fails fast in those cases instead of deadlocking.
/// - Parameters:
///   - file: The source file that starts the transaction.
///   - line: The source line that starts the transaction.
///   - column: The source column that starts the transaction.
///   - body: The synchronous work whose `Stored` assignments are staged.
/// - Returns: The value returned by `body`. The outermost call returns after every
///   staged callback batch commits. A nested call returns to the active outer body
///   without committing.
/// - Throws: The error thrown by `body`. An error escaping the outermost call
///   discards every staged assignment before it is rethrown.
@discardableResult
public func withGraphTransaction<Result, Failure: Error>(
  _ file: StaticString = #fileID,
  _ line: UInt = #line,
  _ column: UInt = #column,
  _ body: () throws(Failure) -> Result
) throws(Failure) -> Result {
  if ThreadLocal.graphTransaction.value != nil {
    Log.logNestedGraphTransaction(file, line, column)
    return try body()
  }

  precondition(
    ThreadLocal.graphTransactionReadScope.value == nil,
    "withGraphTransaction cannot begin from a committed graph read. Move graph mutations outside Computed descriptors."
  )

  let context = GraphTransactionContext()
  let coordinator = GraphTransactionCoordinator.shared
  coordinator.beginTransaction(context)

  var transactionFinished = false
  let previousContext = ThreadLocal.graphTransaction.replaceValue(context)

  defer {
    if !transactionFinished {
      ThreadLocal.graphTransaction.replaceValue(previousContext)
      context.prepareRollback()
      coordinator.finishTransaction(context)
      context.finishRollback()
    }
  }

  let result = try body()

  ThreadLocal.graphTransaction.replaceValue(previousContext)
  commitTransactionBatches(
    beginningWith: context,
    coordinator: coordinator
  )
  coordinator.finishTransaction(context)
  transactionFinished = true

  return result
}

/// Commits the body batch and any mutations synchronously staged by its callbacks.
///
/// Callback delivery is one hook boundary: a callback mutation is immediately
/// readable on the committing thread, but its graph publication is deferred until
/// every callback in the current batch has completed. The next batch is drained
/// before the outer `withGraphTransaction` call returns.
private func commitTransactionBatches(
  beginningWith transaction: GraphTransactionContext,
  coordinator: GraphTransactionCoordinator
) {
  var batch = transaction

  while batch.freezeParticipantsForCommit() {
    let nextBatch = GraphTransactionContext()
    ThreadLocal.graphTransaction.withValue(nextBatch) {
      batch.prepareCommit()
      batch.evaluateCommitComparators()

      let observationDelivery = GraphTransactionObservationDelivery()
      coordinator.withPublicationBarrier(transaction) {
        batch.prepareObservationWillSet(observationDelivery)
      }

      nextBatch.beginCallbackDelivery()
      observationDelivery.deliver()

      let callbackDelivery = GraphTransactionCallbackDelivery()
      coordinator.withPublicationBarrier(transaction) {
        batch.publishCommit()
        batch.prepareCommitInvalidations(callbackDelivery)
      }

      callbackDelivery.deliver()
      batch.deliverCommitCallbacks()
    }

    batch = nextBatch
  }
}

/// A node that can stage and publish its own transaction-local value.
///
/// The context uses this protocol only to coordinate commands. Transaction values
/// remain in the concrete `Stored` node that owns their static type.
protocol GraphTransactionParticipant: AnyObject {

  /// Moves the staged value into node-local commit work.
  func prepareTransactionCommit()

  /// Evaluates the node's existing comparator before publication blocks readers.
  func evaluateTransactionComparator()

  /// Captures Observation's pre-mutation notifications without invoking callbacks.
  func prepareTransactionObservationWillSet(
    _ observationDelivery: GraphTransactionObservationDelivery
  )

  /// Replaces the committed value without running callbacks.
  func publishTransactionCommit()

  /// Marks graph invalidations and queues their callbacks after every participant
  /// has prepared its final committed value.
  func prepareTransactionInvalidations(
    _ callbackDelivery: GraphTransactionCallbackDelivery
  )

  /// Delivers `Stored` callbacks after graph invalidation has completed.
  func deliverTransactionCallbacks()

  /// Detaches the staged value while the transaction still excludes other writers.
  func prepareTransactionRollback(_ transaction: GraphTransactionContext)

  /// Destroys the detached value after releasing the transaction writer slot.
  func finishTransactionRollback(_ transaction: GraphTransactionContext)
}

/// The thread-local command list for one graph transaction commit batch.
///
/// This context intentionally retains only weak, type-erased participants. Each
/// `Stored` node owns its typed staged value directly, which keeps transaction
/// values out of a shared `[ObjectIdentifier: Any]` container.
final class GraphTransactionContext {

  private struct WeakParticipant {
    weak var value: (any GraphTransactionParticipant)?
  }

  private var participants: [WeakParticipant] = []
  private var frozenParticipants: [any GraphTransactionParticipant] = []
  private(set) var recordsDependencies = false

  func register(_ participant: any GraphTransactionParticipant) {
    participants.append(.init(value: participant))
  }

  /// Freezes one strong participant snapshot for every phase of this batch.
  ///
  /// The body owns only weak participant references, so a staged node may still
  /// deallocate before commit. Once publication begins, keeping one stable snapshot
  /// prevents lifetime changes from producing different phase participant sets.
  func freezeParticipantsForCommit() -> Bool {
    frozenParticipants = participants.compactMap(\.value)
    return !frozenParticipants.isEmpty
  }

  func prepareCommit() {
    for participant in frozenParticipants {
      participant.prepareTransactionCommit()
    }
  }

  func evaluateCommitComparators() {
    for participant in frozenParticipants {
      participant.evaluateTransactionComparator()
    }
  }

  func prepareObservationWillSet(
    _ observationDelivery: GraphTransactionObservationDelivery
  ) {
    for participant in frozenParticipants {
      participant.prepareTransactionObservationWillSet(observationDelivery)
    }
  }

  func publishCommit() {
    for participant in frozenParticipants {
      participant.publishTransactionCommit()
    }
  }

  func prepareCommitInvalidations(
    _ callbackDelivery: GraphTransactionCallbackDelivery
  ) {
    for participant in frozenParticipants {
      participant.prepareTransactionInvalidations(callbackDelivery)
    }
  }

  func deliverCommitCallbacks() {
    defer { frozenParticipants.removeAll() }

    for participant in frozenParticipants {
      participant.deliverTransactionCallbacks()
    }
  }

  /// Enables dependency registration while synchronous notification handlers rerun.
  ///
  /// Transaction body and comparator reads remain isolated from the committed graph.
  /// Callback-driven tracking passes may register directly with their leaf `Stored`
  /// dependencies so continuous tracking survives the transaction boundary.
  func beginCallbackDelivery() {
    recordsDependencies = true
  }

  /// Detaches every staged value while this transaction still owns the writer slot.
  ///
  /// The strong snapshot prevents a participant from disappearing between detach
  /// and destruction. Values remain in their concrete nodes throughout both phases.
  func prepareRollback() {
    frozenParticipants = participants.compactMap(\.value)
    for participant in frozenParticipants {
      participant.prepareTransactionRollback(self)
    }
  }

  /// Destroys detached staged values after another writer can safely reenter.
  ///
  /// Releasing an arbitrary `Value` may synchronously run user-defined `deinit`
  /// work. Keeping that destruction outside node locks and the coordinator's writer
  /// slot prevents reentrant graph mutations from waiting on their own rollback.
  func finishRollback() {
    defer { frozenParticipants.removeAll() }

    for participant in frozenParticipants {
      participant.finishTransactionRollback(self)
    }
  }
}

/// A computed node that can mark itself dirty without synchronously invoking user
/// callbacks during transaction publication.
///
/// The pre-publication traversal preserves Observation's `willSet` boundary. The
/// publication traversal then makes every cache dirty before releasing the read
/// barrier and queues graph-tracking callbacks for delivery afterwards. Every
/// concrete dependency target must provide this split; publication fails closed
/// rather than exposing a clean cache after its sources have committed.
protocol GraphTransactionInvalidatableNode: AnyObject {
  func prepareGraphTransactionObservationWillSet(
    _ observationDelivery: GraphTransactionObservationDelivery
  )

  func prepareGraphTransactionInvalidation(
    _ callbackDelivery: GraphTransactionCallbackDelivery
  )
}

/// Freezes Observation's `willSet` work from the committed dependency graph.
///
/// The transaction briefly drains committed readers while this object traverses the
/// graph, then releases that barrier before invoking the captured callbacks. A
/// synchronously delivered callback can therefore read the complete staged snapshot
/// without blocking another thread from reading the old committed graph. Nodes
/// registered afterwards follow the same concurrent-access boundary as a
/// registration racing an ordinary setter after its `willSet` call.
final class GraphTransactionObservationDelivery {

  private var deliveredNodes: Set<ObjectIdentifier> = []
  private var callbacks: [() -> Void] = []

  func append(_ callback: @escaping () -> Void) {
    callbacks.append(callback)
  }

  func prepareWillSet(for edge: Edge) {
    guard let target = edge.to else { return }
    guard let node = target as? any GraphTransactionInvalidatableNode else {
      preconditionFailure(
        "A graph transaction reached a dependency node without two-phase invalidation support."
      )
    }

    let identifier = ObjectIdentifier(node)
    guard deliveredNodes.insert(identifier).inserted else { return }
    node.prepareGraphTransactionObservationWillSet(self)
  }

  func deliver() {
    for callback in callbacks {
      callback()
    }
    callbacks.removeAll()
  }
}

/// User callbacks captured while a transaction marks its dependency graph dirty.
///
/// The publication barrier protects only value installation and dirty-state
/// propagation. Delivering graph-tracking and custom-node callbacks after releasing
/// that barrier avoids making a callback that waits for another thread's graph read
/// deadlock the commit.
final class GraphTransactionCallbackDelivery {

  private var callbacks: [() -> Void] = []

  func append(_ callback: @escaping () -> Void) {
    callbacks.append(callback)
  }

  func prepareInvalidation(for edge: Edge) {
    edge.isPending = true

    guard let node = edge.to else { return }
    guard let node = node as? any GraphTransactionInvalidatableNode else {
      preconditionFailure(
        "A graph transaction reached a dependency node without two-phase invalidation support."
      )
    }

    node.prepareGraphTransactionInvalidation(self)
  }

  func deliver() {
    for callback in callbacks {
      callback()
    }
    callbacks.removeAll()
  }
}

/// Marks an outer committed-graph read so nested node reads keep the same
/// publication snapshot while a writer begins its barrier.
final class GraphTransactionReadScope: @unchecked Sendable {
  static let shared = GraphTransactionReadScope()

  private init() {
  }
}

/// Marks one immediate writer admitted by the coordinator.
///
/// Nested setters on the same thread reuse this scope. A transaction started by a
/// synchronous post-mutation callback returns the counted slot permanently; a later
/// setter in that callback reacquires it lazily before mutating.
final class GraphImmediateWriterScope: @unchecked Sendable {
  var isCounted = false
  var nodeLockDepth = 0

  var canBeginTransaction: Bool {
    nodeLockDepth == 0
  }
}

/// Coordinates cross-node writer exclusion and atomic graph publication.
///
/// A node lock protects one `Stored` value, but it cannot prevent readers from
/// observing a transaction after one participant publishes and before another does.
/// This coordinator therefore suspends other writers for the outer transaction and
/// installs a reader barrier only around the short publication phases. Committed
/// reads remain available while the transaction body only stages values.
///
/// No graph-node lock is held while this coordinator waits. Coordinator admission
/// always precedes node locking, and user callbacks run with neither the condition
/// nor a node lock held.
final class GraphTransactionCoordinator: @unchecked Sendable {

  static let shared = GraphTransactionCoordinator()

  private let condition = NSCondition()
  private var activeTransaction: GraphTransactionContext?
  private var activeImmediateWriterCount = 0
  private var waitingTransactionCount = 0
#if DEBUG
  private var waitingImmediateWriterCount = 0
  private var waitingPublisherCount = 0
#endif
  private var activeReaderCount = 0
  private var isPublishing = false

  func beginTransaction(
    _ transaction: GraphTransactionContext
  ) {
    let immediateWriterScope = ThreadLocal.graphImmediateWriterScope.value
    precondition(
      immediateWriterScope?.canBeginTransaction != false,
      "withGraphTransaction cannot begin while a Stored node lock is held. Start it from onDidSet or another post-mutation callback."
    )

    condition.lock()

    if let immediateWriterScope, immediateWriterScope.isCounted {
      activeImmediateWriterCount -= 1
      immediateWriterScope.isCounted = false
    }

    waitingTransactionCount += 1
    condition.broadcast()

    while activeTransaction != nil || activeImmediateWriterCount != 0 {
      condition.wait()
    }

    waitingTransactionCount -= 1
    activeTransaction = transaction
    condition.unlock()
  }

  /// Runs one value or invalidation publication phase after draining current readers.
  func withPublicationBarrier(
    _ transaction: GraphTransactionContext,
    _ body: () -> Void
  ) {
    beginPublishing(transaction)
    defer { finishPublishing(transaction) }
    body()
  }

  private func beginPublishing(_ transaction: GraphTransactionContext) {
    condition.lock()
    defer { condition.unlock() }

    precondition(activeTransaction === transaction)
    precondition(!isPublishing)
    isPublishing = true

#if DEBUG
    let didWaitForReaders = activeReaderCount != 0
    if didWaitForReaders {
      waitingPublisherCount += 1
      condition.broadcast()
    }
#endif
    while activeReaderCount != 0 {
      condition.wait()
    }
#if DEBUG
    if didWaitForReaders {
      waitingPublisherCount -= 1
    }
#endif
  }

  func finishTransaction(_ transaction: GraphTransactionContext) {
    condition.lock()
    defer { condition.unlock() }

    precondition(activeTransaction === transaction)
    precondition(!isPublishing)

    isPublishing = false
    activeTransaction = nil
    condition.broadcast()
  }

  /// Releases the short publication barrier after all source values and graph
  /// invalidations are coherent, while the transaction continues blocking writers.
  private func finishPublishing(_ transaction: GraphTransactionContext) {
    condition.lock()
    defer { condition.unlock() }

    precondition(activeTransaction === transaction)
    isPublishing = false
    condition.broadcast()
  }

  func withImmediateWrite<Result, Failure: Error>(
    _ body: () throws(Failure) -> Result
  ) throws(Failure) -> Result {
    if let immediateWriterScope = ThreadLocal.graphImmediateWriterScope.value {
      if !immediateWriterScope.isCounted {
        admitImmediateWriter(immediateWriterScope)
      }
      return try body()
    }

    let immediateWriterScope = GraphImmediateWriterScope()
    admitImmediateWriter(immediateWriterScope)

    defer {
      finishImmediateWriter(immediateWriterScope)
    }

    return try ThreadLocal.graphImmediateWriterScope.withValue(
      immediateWriterScope,
      perform: body
    )
  }

  private func admitImmediateWriter(
    _ immediateWriterScope: GraphImmediateWriterScope
  ) {
    precondition(!immediateWriterScope.isCounted)

    condition.lock()
    if ThreadLocal.graphTransactionReadScope.value != nil,
      activeTransaction != nil || waitingTransactionCount != 0
    {
      condition.unlock()
      preconditionFailure(
        "A Stored mutation from a committed graph read cannot wait for an active graph transaction. Move side effects outside Computed descriptors."
      )
    }

#if DEBUG
    var isCountedAsWaiting = false
#endif
    while activeTransaction != nil || waitingTransactionCount != 0 {
#if DEBUG
      if !isCountedAsWaiting {
        isCountedAsWaiting = true
        waitingImmediateWriterCount += 1
        condition.broadcast()
      }
#endif
      condition.wait()
    }
#if DEBUG
    if isCountedAsWaiting {
      waitingImmediateWriterCount -= 1
    }
#endif
    activeImmediateWriterCount += 1
    immediateWriterScope.isCounted = true
    condition.unlock()
  }

  private func finishImmediateWriter(
    _ immediateWriterScope: GraphImmediateWriterScope
  ) {
    condition.lock()
    if immediateWriterScope.isCounted {
      immediateWriterScope.isCounted = false
      activeImmediateWriterCount -= 1
      condition.broadcast()
    }
    condition.unlock()
  }

  func withReadAccess<Result, Failure: Error>(
    _ body: () throws(Failure) -> Result
  ) throws(Failure) -> Result {
    if ThreadLocal.graphTransactionReadScope.value != nil {
      return try body()
    }

    condition.lock()
    while isPublishing {
      condition.wait()
    }
    activeReaderCount += 1
    condition.unlock()

    let previousReadScope = ThreadLocal.graphTransactionReadScope.replaceValue(.shared)

    defer {
      ThreadLocal.graphTransactionReadScope.replaceValue(previousReadScope)
      condition.lock()
      activeReaderCount -= 1
      if activeReaderCount == 0 {
        condition.broadcast()
      }
      condition.unlock()
    }

    return try body()
  }

#if DEBUG
  /// Waits until an immediate writer has reached the coordinator wait branch.
  ///
  /// This deterministic test seam verifies waiting semantics without relying on a
  /// scheduler delay as evidence that an outside setter has attempted its write.
  func waitForImmediateWriterToBlock(until deadline: Date) -> Bool {
    condition.lock()
    defer { condition.unlock() }

    while waitingImmediateWriterCount == 0 {
      guard condition.wait(until: deadline) else { return false }
    }
    return true
  }

  /// Waits until another outer transaction is queued behind the active one.
  func waitForTransactionToBlock(until deadline: Date) -> Bool {
    condition.lock()
    defer { condition.unlock() }

    while waitingTransactionCount == 0 {
      guard condition.wait(until: deadline) else { return false }
    }
    return true
  }

  /// Waits until a publication barrier is blocked by an active committed reader.
  func waitForPublisherToBlock(until deadline: Date) -> Bool {
    condition.lock()
    defer { condition.unlock() }

    while waitingPublisherCount == 0 {
      guard condition.wait(until: deadline) else { return false }
    }
    return true
  }
#endif
}
