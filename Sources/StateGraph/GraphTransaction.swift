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
/// Each nested call creates a savepoint. A successful nested call merges its staged
/// assignments into its parent without publishing them. A throwing nested call
/// restores the values visible when it began, even if its parent catches the error.
/// An error that leaves the outermost call rolls all staged assignments back,
/// including changes from successful nested calls.
///
/// Savepoint completion restores the parent scope and finishes merging or restoring
/// every affected node before releasing discarded values outside node locks. A
/// synchronous `Stored` assignment from their `deinit` joins the parent scope. As
/// with other synchronous callbacks, that cleanup must not wait for another thread
/// to finish a graph write while the outer transaction still owns writer admission.
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
/// - Important: StateGraph's API contract prohibits graph mutations from `Stored`
///   comparators, ``Stored/unsafeModify(_:)``, and ``Computed`` descriptors. DEBUG
///   builds diagnose violations. Non-DEBUG builds omit that tracking, so violating
///   the contract remains unsupported. Mutate from `onDidSet(_:)` or another
///   post-mutation callback instead.
/// - Parameters:
///   - file: The source file that starts the transaction.
///   - line: The source line that starts the transaction.
///   - column: The source column that starts the transaction.
///   - body: The synchronous work whose `Stored` assignments are staged.
/// - Returns: The value returned by `body`. The outermost call returns after every
///   staged Observation-handler batch commits. A nested call returns to the active
///   outer body without committing.
/// - Throws: The error thrown by `body`, after rolling back this call's assignments
///   and those of its nested calls. The parent may catch the error and continue.
@discardableResult
public func withGraphTransaction<Result, Failure: Error>(
  _ file: StaticString = #fileID,
  _ line: UInt = #line,
  _ column: UInt = #column,
  _ body: () throws(Failure) -> Result
) throws(Failure) -> Result {
  assertGraphMutationAllowed("withGraphTransaction")

  if let parent = ThreadLocal.graphTransaction.value {
    let context = GraphTransactionContext(parent: parent)
    ThreadLocal.graphTransaction.replaceValue(context)
    var didMerge = false

    defer {
      // Restore every node before arbitrary value destruction can reenter the graph.
      // Writer admission continues to belong to the outermost transaction.
      ThreadLocal.graphTransaction.replaceValue(parent)
      if !didMerge {
        context.prepareRollback()
      }
      context.finishCleanup()
    }

    let result = try body()
    ThreadLocal.graphTransaction.replaceValue(parent)
    context.prepareMerge(into: parent)
    didMerge = true
    return result
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
      context.finishCleanup()
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

  /// Transfers a successful savepoint's staged value and undo state to its parent.
  /// Discarded parent values remain node-local until every participant has merged.
  func prepareTransactionMerge(
    _ transaction: GraphTransactionContext,
    into parent: GraphTransactionContext
  )

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

  /// Destroys values detached by rollback or merge, outside node locks.
  func finishTransactionCleanup(_ transaction: GraphTransactionContext)
}

/// The thread-local command list for one commit batch or nested savepoint.
///
/// This context intentionally retains only weak, type-erased participants. Each
/// `Stored` node owns its typed staged value directly, which keeps transaction
/// values out of a shared `[ObjectIdentifier: Any]` container.
///
/// Equality represents scope identity, not the contents of the participant list.
/// Node-local staging retains this concrete context until merge, commit, or rollback
/// removes it. The temporary strong participant snapshot is cleared after delivery
/// or cleanup, breaking the corresponding node-to-context ownership cycle.
final class GraphTransactionContext: Equatable {

  /// Returns whether both references identify the same transaction scope.
  static func == (lhs: GraphTransactionContext, rhs: GraphTransactionContext) -> Bool {
    lhs === rhs
  }

  private struct WeakParticipant {
    weak var value: (any GraphTransactionParticipant)?
  }

  private var participants: [WeakParticipant] = []
  private var frozenParticipants: [any GraphTransactionParticipant] = []
  private(set) var recordsDependencies = false

  /// The enclosing savepoint or commit batch. Only nested calls have a parent;
  /// Observation-generated batches are separate roots under the same writer owner.
  let parent: GraphTransactionContext?

  init(parent: GraphTransactionContext? = nil) {
    self.parent = parent
    recordsDependencies = parent?.recordsDependencies ?? false
  }

  func register(_ participant: any GraphTransactionParticipant) {
    participants.append(.init(value: participant))
  }

  /// Merges every surviving participant before releasing superseded parent values.
  /// Nodes retain their typed undo history and register with the parent only if
  /// that scope had not already staged them.
  func prepareMerge(into parent: GraphTransactionContext) {
    precondition(self.parent == parent)
    frozenParticipants = participants.compactMap(\.value)
    for participant in frozenParticipants {
      participant.prepareTransactionMerge(self, into: parent)
    }
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

  /// Detaches this scope's staged values while the outer call owns writer admission.
  ///
  /// The strong snapshot prevents a participant from disappearing between detach
  /// and destruction. Savepoints restore their preceding staging during this phase;
  /// detached values remain in their concrete nodes until cleanup.
  func prepareRollback() {
    frozenParticipants = participants.compactMap(\.value)
    for participant in frozenParticipants {
      participant.prepareTransactionRollback(self)
    }
  }

  /// Destroys detached values after the whole scope has merged or rolled back.
  ///
  /// Releasing an arbitrary `Value` may synchronously run user-defined `deinit`
  /// work. An outer rollback releases writer admission first. A savepoint instead
  /// restores its parent context first, so reentrant assignments join the parent
  /// while the outer transaction continues excluding competing writers.
  func finishCleanup() {
    defer { frozenParticipants.removeAll() }

    for participant in frozenParticipants {
      participant.finishTransactionCleanup(self)
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
