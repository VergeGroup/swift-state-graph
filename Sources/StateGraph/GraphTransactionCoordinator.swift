import Foundation

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

  /// Whether this thread-local scope currently contributes to the global writer count.
  var isCounted = false

  /// The number of logical node-writer reservations currently held by this scope.
  ///
  /// A transaction may begin only after the depth returns to zero. Otherwise a
  /// contending writer could be counted as active while waiting for a reservation
  /// that the transaction-starting scope still owns.
  var nodeReservationDepth = 0

  var canBeginTransaction: Bool {
    nodeReservationDepth == 0
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
/// after the condition mutex, reader barrier, and node locks are released. Immediate
/// comparators and Observation `willSet` delivery also run outside physical node
/// locks while a logical same-node writer reservation preserves assignment order.
///
/// `NSCondition` supplies both the mutex for the coordination state and a wait queue
/// for its predicates. Calling `wait()` atomically releases that mutex while the
/// thread sleeps and reacquires it before the predicate is tested again. It never
/// protects a node's value; each node continues to use its own `NodeLock`. It does
/// protect the transient logical reservations that bridge unlocked comparison and
/// value publication.
///
/// The admission predicates are:
/// - Outer transaction: no active transaction and no active immediate writer.
/// - Immediate write: no active or waiting transaction.
/// - Immediate node write: the node is unreserved or owned by the same scope.
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

  /// One transient same-node writer reservation.
  ///
  /// The owner identity permits synchronous reentrant setters in the same immediate
  /// scope. Depth returns the reservation only after the outermost same-node write
  /// publishes its value.
  private struct ImmediateNodeWriterReservation {
    /// The identity of the `GraphImmediateWriterScope` that acquired this reservation.
    ///
    /// The caller and thread-local storage keep that scope alive until the reservation
    /// is released; the coordinator stores only its non-owning identity for comparison.
    let owner: ObjectIdentifier
    var depth: Int
  }

  /// Active immediate writes keyed by node identity.
  ///
  /// Unlike storing a synchronization object on every node, this table allocates
  /// only for writes that are currently between their old-value snapshot and value
  /// publication.
  private var immediateNodeWriterReservations: [
    ObjectIdentifier: ImmediateNodeWriterReservation
  ] = [:]

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
      "withGraphTransaction cannot begin while a Stored node write is being published. Start it from onDidSet or another post-mutation callback."
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

  /// Runs one nonthrowing immediate assignment with a single outer admission pass.
  ///
  /// A new outer scope is counted and reserves its first node while the condition
  /// mutex is held once. The reservation ends after `prepare` publishes the value;
  /// `deliver` then runs while the outer writer scope remains admitted.
  func withImmediateWrite<Result>(
    to node: ObjectIdentifier,
    prepare: () -> Result,
    deliver: (Result) -> Void
  ) {
    if let immediateWriterScope = ThreadLocal.graphImmediateWriterScope.value {
      if immediateWriterScope.isCounted {
        beginImmediateNodeWrite(to: node, ownedBy: immediateWriterScope)
      } else {
        admitImmediateWriter(immediateWriterScope, reserving: node)
      }

      let result = prepare()
      finishImmediateNodeWrite(to: node, ownedBy: immediateWriterScope)
      deliver(result)
      return
    }

    let immediateWriterScope = GraphImmediateWriterScope()
    admitImmediateWriter(immediateWriterScope, reserving: node)

    defer {
      finishImmediateWriter(immediateWriterScope)
    }

    ThreadLocal.graphImmediateWriterScope.withValue(immediateWriterScope) {
      let result = prepare()
      finishImmediateNodeWrite(to: node, ownedBy: immediateWriterScope)
      deliver(result)
    }
  }

  /// Acquires a node reservation for code whose typed-throws shape prevents a wrapper.
  func beginImmediateNodeWrite(to node: ObjectIdentifier) {
    let immediateWriterScope = requireImmediateWriterScope()
    beginImmediateNodeWrite(to: node, ownedBy: immediateWriterScope)
  }

  /// Balances ``beginImmediateNodeWrite(to:)`` on the current immediate scope.
  func finishImmediateNodeWrite(to node: ObjectIdentifier) {
    let immediateWriterScope = requireImmediateWriterScope()
    finishImmediateNodeWrite(to: node, ownedBy: immediateWriterScope)
  }

  private func requireImmediateWriterScope() -> GraphImmediateWriterScope {
    guard let immediateWriterScope = ThreadLocal.graphImmediateWriterScope.value,
      immediateWriterScope.isCounted
    else {
      preconditionFailure("Stored immediate mutation requires graph writer coordination.")
    }
    return immediateWriterScope
  }

  /// Waits until the node is unreserved or recursively owned by this scope.
  ///
  /// This predicate intentionally ignores queued transactions. The scope was
  /// already admitted before a transaction announced intent, so making it wait
  /// behind that transaction would leave each side waiting for the other.
  private func beginImmediateNodeWrite(
    to node: ObjectIdentifier,
    ownedBy immediateWriterScope: GraphImmediateWriterScope
  ) {
    condition.lock()
    reserveImmediateNodeWriteWhileLocked(
      to: node,
      ownedBy: immediateWriterScope
    )
    condition.unlock()
  }

  /// Waits for and installs a reservation while the caller owns `condition`.
  private func reserveImmediateNodeWriteWhileLocked(
    to node: ObjectIdentifier,
    ownedBy immediateWriterScope: GraphImmediateWriterScope
  ) {
    let owner = ObjectIdentifier(immediateWriterScope)

    while let reservation = immediateNodeWriterReservations[node],
      reservation.owner != owner
    {
      condition.wait()
    }

    if var reservation = immediateNodeWriterReservations[node] {
      precondition(reservation.owner == owner)
      reservation.depth += 1
      immediateNodeWriterReservations[node] = reservation
    } else {
      immediateNodeWriterReservations[node] = .init(owner: owner, depth: 1)
    }
    immediateWriterScope.nodeReservationDepth += 1
  }

  /// Releases one recursive level and wakes same-node writers at depth zero.
  private func finishImmediateNodeWrite(
    to node: ObjectIdentifier,
    ownedBy immediateWriterScope: GraphImmediateWriterScope
  ) {
    let owner = ObjectIdentifier(immediateWriterScope)

    condition.lock()
    guard var reservation = immediateNodeWriterReservations[node] else {
      condition.unlock()
      preconditionFailure("Stored node write reservation is unbalanced.")
    }
    precondition(reservation.owner == owner)
    precondition(reservation.depth > 0)
    precondition(immediateWriterScope.nodeReservationDepth > 0)

    reservation.depth -= 1
    immediateWriterScope.nodeReservationDepth -= 1
    if reservation.depth == 0 {
      immediateNodeWriterReservations.removeValue(forKey: node)
      condition.broadcast()
    } else {
      immediateNodeWriterReservations[node] = reservation
    }
    condition.unlock()
  }

  /// Admits one ordinary `Stored` setter into the immediate-writer group.
  ///
  /// Admission reserves one counted writer slot so an outer transaction cannot begin
  /// until this setter finishes. When `node` is supplied, the same condition-mutex
  /// pass also reserves that node logically. Different-node setters may continue
  /// concurrently; competing same-node setters wait for value publication.
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
    _ immediateWriterScope: GraphImmediateWriterScope,
    reserving node: ObjectIdentifier? = nil
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

    // A first-node reservation stays in this same condition-mutex pass. If another
    // writer owns the node, this scope is already counted before waiting, so a later
    // transaction cannot overtake an admitted write and create a wait cycle.
    if let node {
      reserveImmediateNodeWriteWhileLocked(
        to: node,
        ownedBy: immediateWriterScope
      )
    }
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
    precondition(immediateWriterScope.nodeReservationDepth == 0)
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

    let previousReadScope = ThreadLocal.graphTransactionReadScope.replaceValue(.shared)

    defer {
      ThreadLocal.graphTransactionReadScope.replaceValue(previousReadScope)
      condition.lock()
      activeReaderCount -= 1

      // Only the final active reader can satisfy a publisher's drain predicate.
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
