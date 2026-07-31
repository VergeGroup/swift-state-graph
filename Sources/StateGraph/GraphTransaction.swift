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
/// graph-tracking invalidation and Observation's `didSet` delivery.
///
/// ``Stored/onDidSet(_:)`` and `@GraphStored` property observers retain ordinary
/// assignment semantics: they run synchronously for every staged assignment.
/// `Stored` assignments made by those observers join the same transaction and are
/// discarded if the outer body throws. The observers themselves are not deferred,
/// so rollback cannot undo their non-`Stored` side effects.
///
/// A mutation made by a synchronously delivered Observation handler during commit
/// joins a following batch owned by the same outer transaction. Its staged value is
/// immediately readable by later synchronous handlers on the committing thread, and
/// the batch is published before this function returns. Every batch uses each
/// `Stored` node's ordinary comparator and graph notification pipeline.
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
/// `Computed` values read by the transaction or its synchronous observers are
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
/// - Important: Synchronous observers run before the outer call returns and while
///   writes from other threads remain suspended. Reentrant `Stored` assignments are
///   supported, but a comparator or observer must not synchronously wait for another
///   thread to complete a graph write. Handlers that existing APIs schedule
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
///   staged Observation-handler batch commits. A nested call returns to the active
///   outer body without committing.
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

  // Reserve the single transaction-writer slot before installing thread-local
  // staging. External writes now wait, while committed reads remain available.
  coordinator.beginTransaction(context)

  var transactionFinished = false
  let previousContext = ThreadLocal.graphTransaction.replaceValue(context)

  defer {
    if !transactionFinished {
      // A thrown outer body rolls back as one unit. Detach staged values while no
      // other writer can reach their nodes, then release writer admission before
      // destroying arbitrary values whose deinit may reenter graph mutation.
      ThreadLocal.graphTransaction.replaceValue(previousContext)
      context.prepareRollback()
      coordinator.finishTransaction(context)
      context.finishRollback()
    }
  }

  let result = try body()

  // The body has finished staging. Synchronous Observation delivery receives fresh
  // thread-local contexts inside the iterative commit trampoline below.
  ThreadLocal.graphTransaction.replaceValue(previousContext)
  commitTransactionBatches(
    beginningWith: context,
    coordinator: coordinator
  )

  // Observation-generated batches are now empty, so external writers may resume.
  coordinator.finishTransaction(context)
  transactionFinished = true

  return result
}

/// Commits the body batch and mutations staged by synchronous Observation delivery.
///
/// An Observation-handler mutation is immediately readable on the committing thread,
/// but its graph publication is deferred until every synchronous handler in the
/// current batch has completed. The next batch is drained before the outer
/// `withGraphTransaction` call returns.
///
/// The loop acts as a synchronous trampoline. Observation handlers still run on the
/// current stack, but their mutations never recursively enter the commit pipeline.
/// They stage into a fresh context that the next loop iteration drains after the
/// current delivery wave returns. This prevents recursive stack growth; it does not
/// make a handler that continuously stages new mutations terminate.
private func commitTransactionBatches(
  beginningWith transaction: GraphTransactionContext,
  coordinator: GraphTransactionCoordinator
) {
  var batch = transaction

  while batch.freezeParticipantsForCommit() {
    // Mutations made by synchronous Observation handlers collect here instead of
    // recursively reentering commit. An empty context terminates the next iteration.
    let nextBatch = GraphTransactionContext()
    ThreadLocal.graphTransaction.withValue(nextBatch) {
      // Move every participant's staged value into stable commit work before any
      // comparator runs, so comparator reads see one complete pending snapshot.
      batch.prepareCommit()
      batch.evaluateCommitComparators()

      // Phase 1 captures Observation's pre-mutation traversal without publishing a
      // Stored value or invoking user callbacks. The short barrier prevents a
      // committed reader from crossing the snapshot boundary while work is collected.
      let observationWillSetDelivery = GraphTransactionObservationWillSetDelivery()
      coordinator.withPublicationBarrier(transaction) {
        batch.prepareObservationWillSet(observationWillSetDelivery)
      }

      // Observation delivery is outside the condition mutex, reader barrier, and
      // node locks, although the outer transaction still owns writer admission.
      // Reentrant assignments stage into `nextBatch` and are visible to later
      // callbacks. The committing thread sees pending values while outside readers
      // still see old committed values.
      nextBatch.beginCallbackDelivery()
      observationWillSetDelivery.deliverWillSet()

      // Phase 2 installs all values and propagates dirty state before committed
      // readers resume, preventing a reader from observing a partial batch. It only
      // captures user callbacks; they do not run inside this barrier.
      let callbackDelivery = GraphTransactionCallbackDelivery()
      coordinator.withPublicationBarrier(transaction) {
        batch.publishCommit()
        batch.prepareCommitInvalidations(callbackDelivery)
      }

      // Graph-tracking invalidation is handed off after publication; its user handler
      // is task-enqueued and does not inherit this thread-local transaction.
      // Observation `didSet` may still run synchronously and join `nextBatch`.
      callbackDelivery.deliver()
      batch.deliverObservationDidSet()
    }

    // Continue with Observation-generated work instead of recursively committing
    // from inside handler delivery.
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
    _ observationWillSetDelivery: GraphTransactionObservationWillSetDelivery
  )

  /// Replaces the committed value without running callbacks.
  func publishTransactionCommit()

  /// Marks graph invalidations and queues their callbacks after every participant
  /// has prepared its final committed value.
  func prepareTransactionInvalidations(
    _ callbackDelivery: GraphTransactionCallbackDelivery
  )

  /// Delivers Observation's post-publication notification.
  func deliverTransactionObservationDidSet()

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
    _ observationWillSetDelivery: GraphTransactionObservationWillSetDelivery
  ) {
    for participant in frozenParticipants {
      participant.prepareTransactionObservationWillSet(observationWillSetDelivery)
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

  func deliverObservationDidSet() {
    defer { frozenParticipants.removeAll() }

    for participant in frozenParticipants {
      participant.deliverTransactionObservationDidSet()
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
/// barrier and queues graph-tracking invalidation handoffs for afterwards. Every
/// concrete dependency target must provide this split; publication fails closed
/// rather than exposing a clean cache after its sources have committed.
protocol GraphTransactionInvalidatableNode: AnyObject {
  func prepareGraphTransactionObservationWillSet(
    _ observationWillSetDelivery: GraphTransactionObservationWillSetDelivery
  )

  func prepareGraphTransactionInvalidation(
    _ callbackDelivery: GraphTransactionCallbackDelivery
  )
}

/// Collects Observation `willSet` work for one transaction commit batch.
///
/// Observation requires a pre-mutation notification, but running arbitrary user
/// callbacks while the publication barrier is active could block graph progress or
/// deadlock with work performed by those callbacks. This object separates those
/// responsibilities:
///
/// 1. While committed readers are briefly drained, it traverses the committed
///    dependency graph and queues one `willSet` notification operation for each
///    reachable node in that snapshot.
/// 2. After the barrier and all node locks have been released, it invokes the queued
///    operations. Transaction-local reads on the committing thread then see the
///    complete pending snapshot, while outside readers still see the old committed
///    snapshot.
///
/// The collector does not carry transaction values, publish values, or mark nodes
/// dirty. ``GraphTransactionCallbackDelivery`` separately owns the graph-tracking
/// invalidation work handed off after value publication.
final class GraphTransactionObservationWillSetDelivery {

  /// Nodes already visited during the pre-publication dependency traversal.
  ///
  /// Multiple changed sources can reach the same computed node. Identity
  /// de-duplication gives that node one `willSet` preparation for this commit batch.
  private var visitedNodes: Set<ObjectIdentifier> = []

  /// Deferred registrar operations, kept inert until the publication barrier ends.
  ///
  /// These are not a snapshot of Observation's registered callbacks. The registrar
  /// determines its delivery when each operation invokes `willSet`.
  private var willSetOperations: [() -> Void] = []

  /// Queues one registrar `willSet` operation without invoking user code.
  func appendWillSetOperation(_ operation: @escaping () -> Void) {
    willSetOperations.append(operation)
  }

  /// Continues pre-publication traversal through an outgoing dependency edge.
  ///
  /// A diamond-shaped graph can encounter the same target more than once, so each
  /// target is prepared only on its first visit. Preparation may append its own
  /// Observation notification operation and recursively visit its outgoing edges;
  /// it must not dirty the target or invoke user code.
  func prepareWillSet(for edge: Edge) {
    guard let target = edge.to else { return }
    guard let node = target as? any GraphTransactionInvalidatableNode else {
      preconditionFailure(
        "A graph transaction reached a dependency node without two-phase invalidation support."
      )
    }

    let identifier = ObjectIdentifier(node)
    guard visitedNodes.insert(identifier).inserted else { return }
    node.prepareGraphTransactionObservationWillSet(self)
  }

  /// Invokes the queued `willSet` operations after leaving the publication barrier.
  func deliverWillSet() {
    for operation in willSetOperations {
      operation()
    }
    willSetOperations.removeAll()
  }
}

/// Graph-tracking invalidation work captured while a transaction marks nodes dirty.
///
/// The publication barrier protects only value installation and dirty-state
/// propagation. Running each `TrackingRegistration` handoff after releasing that
/// barrier avoids executing its synchronization and task scheduling while committed
/// reads are blocked. The registration enqueues its user handler separately; that
/// handler does not inherit the transaction's thread-local context.
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

  /// Actions are appended and drained by the one thread that owns this scope.
  private var deferredActions: [() -> Void] = []

  func append(_ action: @escaping () -> Void) {
    deferredActions.append(action)
  }

  func finish() {
    let actions = deferredActions
    deferredActions = []

    for action in actions {
      action()
    }
  }
}

/// Defers work until the current committed graph read has released its barrier.
///
/// A `Computed` evaluation and all of its nested node reads share one committed
/// graph read scope. When called from that scope, `action` runs after the scope's
/// thread-local marker, reader admission, and node locks have been released. This
/// is useful for ending the lifetime of values whose `deinit` may read the graph.
///
/// Graph transactions do not use the committed read scope. When no such scope is
/// active, the function returns the original action without ending the lifetime of
/// its captures. The caller can then transfer that action to another safe execution
/// context.
///
/// - Parameter action: Work to perform after the current read completes.
/// - Returns: `nil` when `action` was deferred, or the unconsumed action when no
///   committed graph read is active.
public func deferUntilGraphReadCompletes(
  _ action: @escaping () -> Void
) -> (() -> Void)? {
  guard let scope = ThreadLocal.graphTransactionReadScope.value else {
    return action
  }

  scope.append(action)
  return nil
}

/// Marks one immediate writer admitted by the coordinator.
///
/// Nested setters on the same thread reuse this scope. A transaction started by a
/// synchronous post-mutation callback returns the counted slot permanently; a later
/// setter in that callback reacquires it lazily before mutating.
final class GraphImmediateWriterScope: @unchecked Sendable {

  /// Whether this thread-local scope currently contributes to the global writer count.
  var isCounted = false

  /// The number of `Stored` node locks currently held by this writer thread.
  ///
  /// A transaction may begin from this scope only after the depth returns to zero;
  /// otherwise it could wait while still blocking another graph operation.
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
/// always precedes node locking. Callbacks captured by transaction publication run
/// after the condition mutex, reader barrier, and node locks are released; ordinary
/// immediate setters retain their existing callback lock semantics.
///
/// `NSCondition` supplies both the mutex for the coordination state and a wait queue
/// for its predicates. Calling `wait()` atomically releases that mutex while the
/// thread sleeps and reacquires it before the predicate is tested again. It never
/// protects a node's value; each node continues to use its own `NodeLock`.
///
/// The admission predicates are:
/// - Outer transaction: no active transaction and no active immediate writer.
/// - Immediate write: no active or waiting transaction.
/// - Committed read: publication is not in progress.
/// - Publication: close read admission, then drain every active reader.
///
/// A broadcast only means that one of these predicates may have changed. Every
/// awakened thread must recheck its own predicate in a `while` loop. Broadcasting
/// is intentional because this one condition hosts several waiter classes; waking
/// one arbitrary waiter could select a thread whose predicate is still false.
final class GraphTransactionCoordinator: @unchecked Sendable {

  static let shared = GraphTransactionCoordinator()

  /// Protects all coordinator state below and wakes threads when a predicate may change.
  private let condition = NSCondition()

  /// The logical writer owner; the condition mutex is not held for its lifetime.
  ///
  /// A non-nil value excludes every immediate writer and implies that
  /// `activeImmediateWriterCount` is zero.
  private var activeTransaction: GraphTransactionContext?

  /// Ordinary setters admitted before any transaction began waiting.
  ///
  /// Multiple setters may run concurrently against different nodes. A transaction
  /// waits for this count to reach zero before it claims writer ownership.
  private var activeImmediateWriterCount = 0

  /// Transactions that announced writer intent but have not claimed ownership.
  ///
  /// A nonzero count prevents new immediate writers from continually overtaking a
  /// queued transaction while already-admitted writers drain.
  private var waitingTransactionCount = 0

#if DEBUG
  /// Deterministic test seams for observing each blocking branch.
  private var waitingImmediateWriterCount = 0
  private var waitingPublisherCount = 0
#endif

  /// Outermost committed read scopes that may currently hold node or Computed locks.
  private var activeReaderCount = 0

  /// Whether a transaction has closed admission to new committed reads.
  ///
  /// `Publishing` here means running a short commit phase that must not overlap a
  /// committed read: either traversing the pre-mutation graph to collect Observation
  /// `willSet` operations, or installing every staged `Stored` value and propagating
  /// invalidations as one coherent committed graph. Existing readers drain before the
  /// phase body starts; new readers wait until this flag becomes `false`.
  private var isPublishing = false

  // MARK: - Outer Transaction

  /// Acquires exclusive graph-writer ownership for an outer transaction.
  ///
  /// Once this transaction is counted as waiting, new immediate writers stop at
  /// their admission predicate. Writers already admitted are allowed to finish.
  func beginTransaction(
    _ transaction: GraphTransactionContext
  ) {
    let immediateWriterScope = ThreadLocal.graphImmediateWriterScope.value
    precondition(
      immediateWriterScope?.canBeginTransaction != false,
      "withGraphTransaction cannot begin while a Stored node lock is held. Start it from onDidSet or another post-mutation callback."
    )

    condition.lock()

    // A post-mutation callback may begin a transaction while its thread-local
    // immediate-writer scope still exists. Once its node lock is released, returning
    // that counted slot prevents the transaction from waiting for its own thread.
    if let immediateWriterScope, immediateWriterScope.isCounted {
      activeImmediateWriterCount -= 1
      immediateWriterScope.isCounted = false
    }

    // Publish writer preference before waiting so no later ordinary setter can enter
    // while the currently admitted setters are draining.
    waitingTransactionCount += 1
    condition.broadcast()

    // `wait()` releases the condition mutex. Finishing writers and transactions can
    // therefore update these predicates and wake this thread without spinning.
    while activeTransaction != nil || activeImmediateWriterCount != 0 {
      condition.wait()
    }

    waitingTransactionCount -= 1
    activeTransaction = transaction
    condition.unlock()
  }

  /// Runs one transaction phase after excluding committed readers.
  ///
  /// The condition mutex is released before `body` begins. The closure may therefore
  /// acquire participant node locks without holding both lock domains at once. The
  /// outer transaction continues to exclude other writers for the entire phase.
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

    // Close admission before draining. Existing readers can now only finish, so the
    // count moves monotonically toward zero while every new reader waits.
    isPublishing = true

#if DEBUG
    let didWaitForReaders = activeReaderCount != 0
    if didWaitForReaders {
      waitingPublisherCount += 1
      condition.broadcast()
    }
#endif

    // An existing Computed evaluation may span several node reads. Waiting for its
    // outer read scope prevents publication from splitting that snapshot.
    while activeReaderCount != 0 {
      condition.wait()
    }
#if DEBUG
    if didWaitForReaders {
      waitingPublisherCount -= 1
    }
#endif
  }

  /// Releases writer ownership after every commit batch and callback has drained.
  func finishTransaction(_ transaction: GraphTransactionContext) {
    condition.lock()
    defer { condition.unlock() }

    precondition(activeTransaction === transaction)
    precondition(!isPublishing)

    activeTransaction = nil

    // Both queued transactions and immediate writers may now satisfy their
    // predicates. Each awakened thread rechecks its own `while` condition.
    condition.broadcast()
  }

  /// Releases the short publication barrier after all source values and graph
  /// invalidations are coherent, while the transaction continues blocking writers.
  private func finishPublishing(_ transaction: GraphTransactionContext) {
    condition.lock()
    defer { condition.unlock() }

    precondition(activeTransaction === transaction)
    precondition(isPublishing)
    isPublishing = false

    // Committed readers may resume, but immediate writers still observe the active
    // outer transaction and remain suspended.
    condition.broadcast()
  }

  // MARK: - Immediate Writes

  /// Runs an ordinary `Stored` setter after admitting its thread as a graph writer.
  ///
  /// Reentrant setters reuse one thread-local scope, so nested callback work is
  /// counted once rather than appearing as multiple independent writers.
  func withImmediateWrite<Result, Failure: Error>(
    _ body: () throws(Failure) -> Result
  ) throws(Failure) -> Result {
    if let immediateWriterScope = ThreadLocal.graphImmediateWriterScope.value {
      // Starting a transaction from a post-mutation callback returns the counted
      // slot. A later ordinary setter in that callback must acquire it again.
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

  /// Admits one ordinary `Stored` setter into the immediate-writer group.
  ///
  /// Admission does not acquire a node lock or serialize ordinary setters with one
  /// another. It reserves one counted writer slot so an outer transaction cannot
  /// begin until this setter finishes. Different admitted setters may continue
  /// concurrently and rely on each `Stored` node's lock for node-local exclusion.
  ///
  /// If a transaction is active or already waiting, this method sleeps on
  /// `condition` until the transactions ahead of this setter have completed. Giving
  /// queued transactions priority prevents a continuous stream of ordinary setters
  /// from starving them.
  ///
  /// On return, `immediateWriterScope.isCounted` is `true`,
  /// `activeImmediateWriterCount` includes this scope, and the condition mutex has
  /// been released. The caller may then enter the ordinary node mutation pipeline.
  ///
  /// - Precondition: `immediateWriterScope` is not already counted. A mutation
  ///   initiated from a committed graph read must also be able to enter without
  ///   waiting; otherwise this method fails before creating a lock-order cycle.
  private func admitImmediateWriter(
    _ immediateWriterScope: GraphImmediateWriterScope
  ) {
    precondition(!immediateWriterScope.isCounted)

    condition.lock()

    // A committed Computed read may own its evaluation lock. Waiting for a
    // transaction from inside that descriptor could invert Computed and coordinator
    // ordering, so fail before entering the wait branch.
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

    // A queued transaction has priority over new setters. This lets already-admitted
    // writers drain instead of allowing an unbounded stream of setters to starve it.
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

    // Count admission before releasing the condition mutex so a transaction cannot
    // claim ownership while this setter is about to acquire its node lock.
    activeImmediateWriterCount += 1
    immediateWriterScope.isCounted = true
    condition.unlock()
  }

  /// Releases an ordinary setter's counted writer slot.
  ///
  /// The scope may already have relinquished its slot when a post-mutation callback
  /// starts a transaction. Otherwise, decrementing the count wakes any outer
  /// transaction waiting for the last admitted setter to finish.
  private func finishImmediateWriter(
    _ immediateWriterScope: GraphImmediateWriterScope
  ) {
    condition.lock()
    if immediateWriterScope.isCounted {
      immediateWriterScope.isCounted = false
      activeImmediateWriterCount -= 1

      // A transaction waiting for the final active setter can now retest its predicate.
      condition.broadcast()
    }
    condition.unlock()
  }

  // MARK: - Committed Reads

  /// Runs one committed-graph read scope that cannot overlap transaction publication.
  ///
  /// A thread-local marker lets every nested `Stored` and `Computed` read remain in
  /// the same scope. The reader count therefore covers an entire Computed evaluation,
  /// so a transaction publication cannot split its dependency reads. Ordinary
  /// immediate writes retain their existing concurrent-read semantics.
  func withReadAccess<Result, Failure: Error>(
    _ body: () throws(Failure) -> Result
  ) throws(Failure) -> Result {
    // Nested node reads inherit the outer admission and cannot independently cross
    // a transaction-publication boundary.
    if ThreadLocal.graphTransactionReadScope.value != nil {
      return try body()
    }

    condition.lock()

    // Publication closes admission before changing any participant. Waiting here
    // happens without a node lock, so the publisher can finish and reopen the gate.
    while isPublishing {
      condition.wait()
    }

    // Count this reader before releasing the condition mutex. A publisher can now
    // either observe it and wait, or close admission only after this scope finishes.
    activeReaderCount += 1
    condition.unlock()

    let readScope = GraphTransactionReadScope()
    let previousReadScope = ThreadLocal.graphTransactionReadScope.replaceValue(readScope)

    defer {
      ThreadLocal.graphTransactionReadScope.replaceValue(previousReadScope)
      condition.lock()
      activeReaderCount -= 1

      // Only the final active reader can satisfy a publisher's drain predicate.
      if activeReaderCount == 0 {
        condition.broadcast()
      }
      condition.unlock()
      readScope.finish()
    }

    return try body()
  }

#if DEBUG
  /// Waits until an immediate writer has reached the coordinator wait branch.
  ///
  /// This deterministic test seam verifies waiting semantics without relying on a
  /// scheduler delay as evidence that an outside setter has attempted its write.
  func __testing__waitForImmediateWriterToBlock(until deadline: Date) -> Bool {
    condition.lock()
    defer { condition.unlock() }

    while waitingImmediateWriterCount == 0 {
      guard condition.wait(until: deadline) else { return false }
    }
    return true
  }

  /// Waits until another outer transaction is queued behind the active one.
  func __testing__waitForTransactionToBlock(until deadline: Date) -> Bool {
    condition.lock()
    defer { condition.unlock() }

    while waitingTransactionCount == 0 {
      guard condition.wait(until: deadline) else { return false }
    }
    return true
  }

  /// Waits until a publication barrier is blocked by an active committed reader.
  func __testing__waitForPublisherToBlock(until deadline: Date) -> Bool {
    condition.lock()
    defer { condition.unlock() }

    while waitingPublisherCount == 0 {
      guard condition.wait(until: deadline) else { return false }
    }
    return true
  }
#endif
}
