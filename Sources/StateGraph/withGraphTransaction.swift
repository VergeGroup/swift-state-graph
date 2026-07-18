/// Performs a group of StateGraph mutations as a single batch.
///
/// Assignments made by `body` are staged on the current thread. A staged value is
/// readable through the same node immediately, but storage and observers are updated
/// only after the outermost transaction body returns successfully. If `body` throws,
/// the assignments made by that transaction scope are discarded.
///
/// Nested transactions act as savepoints. A nested failure discards only the nested
/// scope when its error is caught by the outer body. A failure from the outermost scope
/// discards the entire batch.
///
/// StateGraph runs each synchronous commit hook in a separate follow-up batch. Direct
/// assignments and nested transactions are immediately readable inside that hook and
/// coalesce together. The follow-up batch is hidden again when the hook returns, then
/// committed in FIFO order after the current batch finishes.
///
/// Property observers and `onDidSet(_:)` handlers are separate hooks. One Observation
/// registrar publication is one hook, so subscribers synchronously dispatched by the
/// same publication share its staged values.
///
/// A `willSet` hook runs before physical application and reads the pre-batch committed
/// snapshot. Post-apply hooks such as `onDidSet(_:)`, `didSet`, and synchronous
/// Observation publication read the applied batch snapshot. In either phase, a hook's
/// own staged writes take precedence until that hook returns.
///
/// - Important: A transaction batches publication; it does not provide cross-thread
///   snapshot isolation. Code on another thread can continue to read the committed
///   values while `body` is running. A concurrent writer can be overwritten by the
///   later transaction commit. For the outer batch, callback `oldValue` arguments are
///   the values captured when each node was first staged. A batch started by a commit
///   callback rebases those values immediately before its deferred commit.
///
/// - Important: Mutating multiple nodes that share one external backing location in the
///   same transaction is unsupported because `Storage` does not expose backing identity.
///   Use one writer node for each backing location. An unstaged alias can publish the
///   final committed snapshot, but it does not expose another node's staged value while
///   `body` is running.
///
/// - Important: Only work that runs synchronously before a hook returns participates
///   in its follow-up batch. Deferred or asynchronous work runs outside the transaction's
///   commit wave.
///
/// - Important: A custom `Storage.value` accessor is not a commit hook. StateGraph calls
///   it while holding the owning node's lock, so re-entering any StateGraph node from an
///   accessor is unsupported. `StorageContext.notifyStorageUpdated()` is the only
///   supported callback into StateGraph from a backing store.
///
/// - Parameter body: The operation that stages StateGraph mutations.
/// - Returns: The value returned by `body`. A transaction started inside a synchronous
///   commit callback returns before its follow-up batch is applied, while that callback
///   can continue to read the staged values until it returns.
@discardableResult
public func withGraphTransaction<Result, Failure: Error>(
  _ body: () throws(Failure) -> Result
) throws(Failure) -> Result {
  if let transaction = ThreadLocal.transaction.value, transaction.isCollecting {
    let checkpoint = transaction.makeCheckpoint()
    var succeeded = false

    defer {
      if !succeeded {
        transaction.rollback(to: checkpoint)
      }
    }

    let result = try body()
    succeeded = true
    return result
  }

  if let committingTransaction = ThreadLocal.committingTransaction.value,
     committingTransaction.defersMutations
  {
    return try committingTransaction.withDeferredMutationScope(body)
  }

  let transaction = GraphTransaction()
  let perform: () throws(Failure) -> Result = {
    var succeeded = false

    defer {
      if !succeeded {
        transaction.rollback(to: transaction.initialCheckpoint)
      }
    }

    let result = try body()
    transaction.commit()
    succeeded = true
    return result
  }

  return try ThreadLocal.transaction.withValue(transaction, perform: perform)
}

/// A value lookup in the current transaction.
///
/// This enum preserves the distinction between an absent staged value and a staged
/// value whose `Value` is itself `Optional.none`.
enum GraphTransactionValue<Value> {
  case absent
  case staged(Value)
}

/// The lifecycle of the outermost transaction.
enum GraphTransactionPhase {
  case collecting
  case preparing
  case applying
  case publishing
  case completing
  case finished
}

/// A savepoint into a transaction's undo log.
struct GraphTransactionCheckpoint {
  fileprivate let undoActionCount: Int
}

/// Type-erased behavior required to commit a staged node mutation.
private protocol AnyGraphTransactionMutation: AnyObject {
  func rebaseInitialValue()
  func prepare(in transaction: GraphTransaction)
  func apply()
  func publish(into transaction: GraphTransaction)
  func complete(in transaction: GraphTransaction)
}

/// A coalesced mutation for one node.
///
/// The storage type is intentionally hidden in the operation closures, allowing one
/// transaction to stage nodes backed by different `Storage` implementations.
private final class GraphTransactionMutation<Value>: AnyGraphTransactionMutation {
  struct Snapshot {
    let finalValue: Value
    let willSetObserver: ((Value, Value) -> Void)?
    let didSetObserver: ((Value, Value) -> Void)?
  }

  var initialValue: Value
  var finalValue: Value
  var willSetObserver: ((Value, Value) -> Void)?
  var didSetObserver: ((Value, Value) -> Void)?

  private let shouldNotify: (Value, Value) -> Bool
  private let readCurrentValue: () -> Value
  private let applyValue: (Value) -> Void
  private let publishValue: (Value, Value, Bool, GraphTransaction) -> Void
  private let completeValue: (Value, Value) -> Void
  private var publishesChange = false

  init(
    initialValue: Value,
    finalValue: Value,
    willSetObserver: ((Value, Value) -> Void)?,
    didSetObserver: ((Value, Value) -> Void)?,
    shouldNotify: @escaping (Value, Value) -> Bool,
    readCurrentValue: @escaping () -> Value,
    applyValue: @escaping (Value) -> Void,
    publishValue: @escaping (Value, Value, Bool, GraphTransaction) -> Void,
    completeValue: @escaping (Value, Value) -> Void
  ) {
    self.initialValue = initialValue
    self.finalValue = finalValue
    self.willSetObserver = willSetObserver
    self.didSetObserver = didSetObserver
    self.shouldNotify = shouldNotify
    self.readCurrentValue = readCurrentValue
    self.applyValue = applyValue
    self.publishValue = publishValue
    self.completeValue = completeValue
  }

  func snapshot() -> Snapshot {
    Snapshot(
      finalValue: finalValue,
      willSetObserver: willSetObserver,
      didSetObserver: didSetObserver
    )
  }

  func restore(_ snapshot: Snapshot) {
    finalValue = snapshot.finalValue
    willSetObserver = snapshot.willSetObserver
    didSetObserver = snapshot.didSetObserver
  }

  func update(
    finalValue: Value,
    willSetObserver: ((Value, Value) -> Void)?,
    didSetObserver: ((Value, Value) -> Void)?
  ) {
    self.finalValue = finalValue

    // A direct access to the backing node should not erase an observer that was
    // already staged through the property in the same batch.
    if let willSetObserver {
      self.willSetObserver = willSetObserver
    }
    if let didSetObserver {
      self.didSetObserver = didSetObserver
    }
  }

  func rebaseInitialValue() {
    initialValue = readCurrentValue()
  }

  func prepare(in transaction: GraphTransaction) {
    publishesChange = shouldNotify(initialValue, finalValue)
    if let willSetObserver {
      transaction.withDeferredMutationScope {
        willSetObserver(initialValue, finalValue)
      }
    }
  }

  func apply() {
    applyValue(finalValue)
  }

  func publish(into transaction: GraphTransaction) {
    publishValue(initialValue, finalValue, publishesChange, transaction)
  }

  func complete(in transaction: GraphTransaction) {
    transaction.withDeferredMutationScope {
      completeValue(initialValue, finalValue)
    }

    if let didSetObserver {
      transaction.withDeferredMutationScope {
        didSetObserver(initialValue, finalValue)
      }
    }
  }
}

/// A type-safe box stored in the transaction-local computed-value cache.
private final class GraphTransactionComputedValue<Value> {
  let value: Value

  init(_ value: Value) {
    self.value = value
  }
}

/// Serializes one root commit and every follow-up batch it creates.
///
/// A shared queue prevents a callback created by an earlier follow-up batch from
/// overtaking sibling batches that were already scheduled by the root commit.
final class GraphTransactionCommitQueue {
  private var actions: [() -> Void] = []
  private var nextActionIndex = 0

  func enqueue(_ action: @escaping () -> Void) {
    actions.append(action)
  }

  func drain() {
    while nextActionIndex < actions.count {
      let action = actions[nextActionIndex]
      nextActionIndex += 1
      action()
    }

    actions.removeAll()
    nextActionIndex = 0
  }
}

/// Coordinates staged mutations and their commit-time publication.
final class GraphTransaction {
  let initialCheckpoint = GraphTransactionCheckpoint(undoActionCount: 0)

  private(set) var phase: GraphTransactionPhase = .collecting
  private var mutationsByNode: [ObjectIdentifier: any AnyGraphTransactionMutation] = [:]
  private var orderedMutations: [any AnyGraphTransactionMutation] = []
  private var undoActions: [() -> Void] = []
  private var pendingRegistrations: Set<TrackingRegistration> = []
  private var pendingObservationPublications: [() -> Void] = []
  private var pendingStoragePublicationNodes: Set<ObjectIdentifier> = []
  private var pendingStoragePublications: [(GraphTransaction) -> Void] = []
  private var deferredActions: [() -> Void] = []
  private var computedValues: [ObjectIdentifier: Any] = [:]

  var isCollecting: Bool {
    phase == .collecting
  }

  var hasStagedMutations: Bool {
    !orderedMutations.isEmpty
  }

  var defersMutations: Bool {
    switch phase {
    case .preparing, .applying, .publishing, .completing:
      return true
    case .collecting, .finished:
      return false
    }
  }

  func makeCheckpoint() -> GraphTransactionCheckpoint {
    precondition(isCollecting, "A savepoint can only be created while collecting mutations")
    return GraphTransactionCheckpoint(undoActionCount: undoActions.count)
  }

  func stagedValue<Value>(for node: AnyObject, as _: Value.Type) -> GraphTransactionValue<Value> {
    guard isCollecting else {
      return .absent
    }

    guard
      let mutation = mutationsByNode[ObjectIdentifier(node)]
        as? GraphTransactionMutation<Value>
    else {
      return .absent
    }

    return .staged(mutation.finalValue)
  }

  func stage<Value>(
    node: AnyObject,
    initialValue: @autoclosure () -> Value,
    finalValue: Value,
    willSetObserver: ((Value, Value) -> Void)?,
    didSetObserver: ((Value, Value) -> Void)?,
    shouldNotify: @escaping (Value, Value) -> Bool,
    readCurrentValue: @escaping () -> Value,
    applyValue: @escaping (Value) -> Void,
    publishValue: @escaping (Value, Value, Bool, GraphTransaction) -> Void,
    completeValue: @escaping (Value, Value) -> Void
  ) {
    precondition(isCollecting, "Mutations can only be staged while the transaction body is running")
    computedValues.removeAll()

    let key = ObjectIdentifier(node)

    if let mutation = mutationsByNode[key] as? GraphTransactionMutation<Value> {
      let snapshot = mutation.snapshot()
      undoActions.append { [unowned mutation] in
        mutation.restore(snapshot)
      }
      mutation.update(
        finalValue: finalValue,
        willSetObserver: willSetObserver,
        didSetObserver: didSetObserver
      )
      return
    }

    precondition(mutationsByNode[key] == nil, "A node changed its value type within one transaction")

    let mutation = GraphTransactionMutation(
      initialValue: initialValue(),
      finalValue: finalValue,
      willSetObserver: willSetObserver,
      didSetObserver: didSetObserver,
      shouldNotify: shouldNotify,
      readCurrentValue: readCurrentValue,
      applyValue: applyValue,
      publishValue: publishValue,
      completeValue: completeValue
    )

    mutationsByNode[key] = mutation
    orderedMutations.append(mutation)
    undoActions.append { [unowned self, mutation] in
      self.mutationsByNode.removeValue(forKey: key)
      let removedMutation = self.orderedMutations.removeLast()
      precondition(removedMutation === mutation, "Transaction mutations must roll back in reverse order")
    }
  }

  func rollback(to checkpoint: GraphTransactionCheckpoint) {
    precondition(isCollecting, "Only a collecting transaction can roll back")
    precondition(checkpoint.undoActionCount <= undoActions.count, "Invalid transaction checkpoint")

    let actions = Array(undoActions[checkpoint.undoActionCount...]).reversed()
    undoActions.removeSubrange(checkpoint.undoActionCount...)

    for action in actions {
      action()
    }

    computedValues.removeAll()
  }

  func computedValue<Value>(for node: AnyObject, compute: () -> Value) -> Value {
    let key = ObjectIdentifier(node)

    if let cachedValue = computedValues[key] as? GraphTransactionComputedValue<Value> {
      return cachedValue.value
    }

    let value = compute()
    computedValues[key] = GraphTransactionComputedValue(value)
    return value
  }

  func enqueue(_ registrations: Set<TrackingRegistration>) {
    pendingRegistrations.formUnion(registrations)
  }

  func enqueueObservation(_ publication: @escaping () -> Void) {
    pendingObservationPublications.append(publication)
  }

  func enqueueStoragePublication(
    for node: AnyObject,
    _ publication: @escaping (GraphTransaction) -> Void
  ) {
    guard pendingStoragePublicationNodes.insert(ObjectIdentifier(node)).inserted else {
      return
    }
    pendingStoragePublications.append(publication)
  }

  /// Runs one synchronous commit callback in its own follow-up batch.
  ///
  /// The callback can read its staged writes immediately. Its batch becomes hidden
  /// when the callback returns, then joins the current commit wave in FIFO order.
  @discardableResult
  func withDeferredMutationScope<Result, Failure: Error>(
    _ body: () throws(Failure) -> Result
  ) throws(Failure) -> Result {
    precondition(defersMutations, "A deferred mutation scope requires an active commit")

    let transaction = GraphTransaction()
    var succeeded = false

    defer {
      if !succeeded {
        transaction.rollback(to: transaction.initialCheckpoint)
      }
    }

    let result = try ThreadLocal.transaction.withValue(transaction, perform: body)
    succeeded = true

    guard transaction.hasStagedMutations else {
      return result
    }

    deferUntilAfterCompletion {
      transaction.commit(rebasingInitialValues: true)
    }
    return result
  }

  func deferUntilAfterCompletion(_ action: @escaping () -> Void) {
    precondition(defersMutations, "Only a committing transaction can defer mutations")
    deferredActions.append(action)
  }

  func containsMutation(for node: AnyObject) -> Bool {
    mutationsByNode[ObjectIdentifier(node)] != nil
  }

  func commit(rebasingInitialValues: Bool = false) {
    precondition(isCollecting, "A transaction can only commit once")

    let commit = { [self] in
      ThreadLocal.committingTransaction.withValue(self) {
        ThreadLocal.transaction.withValue(nil) {
          performCommit(rebasingInitialValues: rebasingInitialValues)
        }
      }
    }

    if let commitQueue = ThreadLocal.transactionCommitQueue.value {
      commitQueue.enqueue(commit)
      return
    }

    let commitQueue = GraphTransactionCommitQueue()
    ThreadLocal.transactionCommitQueue.withValue(commitQueue) {
      commitQueue.enqueue(commit)
      commitQueue.drain()
    }
  }

  private func performCommit(rebasingInitialValues: Bool) {

    let mutations = orderedMutations
    undoActions.removeAll()

    if rebasingInitialValues {
      for mutation in mutations {
        mutation.rebaseInitialValue()
      }
    }

    phase = .preparing
    for mutation in mutations {
      mutation.prepare(in: self)
    }

    phase = .applying
    for mutation in mutations {
      mutation.apply()
    }

    phase = .publishing
    for mutation in mutations {
      mutation.publish(into: self)
    }

    // A storage setter can synchronously notify another node backed by the same
    // persistence key. Publish those aliases only after every staged value is
    // applied, but before Observation and graph-tracking callbacks are flushed.
    var storagePublicationIndex = 0
    while storagePublicationIndex < pendingStoragePublications.count {
      let publication = pendingStoragePublications[storagePublicationIndex]
      storagePublicationIndex += 1
      publication(self)
    }
    pendingStoragePublications.removeAll()
    pendingStoragePublicationNodes.removeAll()

    let observationPublications = pendingObservationPublications
    pendingObservationPublications.removeAll()
    for publication in observationPublications {
      withDeferredMutationScope(publication)
    }

    let registrations = pendingRegistrations
    pendingRegistrations.removeAll()
    for registration in registrations {
      registration.perform()
    }

    // Writes performed by completion callbacks are deferred until every original
    // mutation has reported its initial-to-final transition.
    phase = .completing
    for mutation in mutations {
      mutation.complete(in: self)
    }

    mutationsByNode.removeAll()
    orderedMutations.removeAll()
    computedValues.removeAll()
    phase = .finished

    let actions = deferredActions
    deferredActions.removeAll()
    for action in actions {
      action()
    }
  }
}
