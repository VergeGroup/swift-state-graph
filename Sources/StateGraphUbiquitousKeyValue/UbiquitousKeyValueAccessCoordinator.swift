import Foundation

/// Serializes this module's access to the app-wide iCloud key-value store and
/// publishes graph updates synchronously after releasing the access lock.
final class UbiquitousKeyValueAccessCoordinator: @unchecked Sendable {
  typealias ChangeHandler = @Sendable (UbiquitousKeyValueStoreChange) -> Void

  private struct PublicationBatch: Sendable {
    let id: UInt64
    let publications: [@Sendable () -> Void]
  }

  private struct PublicationTicket {
    let id: UInt64
    let shouldDrain: Bool
  }

  static let shared = UbiquitousKeyValueAccessCoordinator(
    client: FoundationUbiquitousKeyValueStoreClient(store: .default)
  )

  /// The unchecked sendability boundary is owned here; every client operation
  /// runs while `accessLock` is held.
  nonisolated(unsafe)
  private let client: any UbiquitousKeyValueStoreClient
  private let accessLock = NSRecursiveLock()
  private let publicationCondition = NSCondition()
  private let drainingContextKey =
    "org.vergegroup.state-graph.ubiquitous-key-value-publication-drainer.\(UUID())"

  private var accessDepth = 0
  private var currentPublications: [@Sendable () -> Void] = []

  private var nextBatchID: UInt64 = 0
  private var completedThroughBatchID: UInt64 = 0
  private var completedOutOfOrderBatchIDs: Set<UInt64> = []
  private var isDraining = false
  private var pendingBatches: [PublicationBatch] = []

  private var changeHandlers: [String: [UUID: ChangeHandler]] = [:]
  private var storeObservation: UbiquitousKeyValueStoreObservation?
  private var hasRequestedInitialSynchronization = false

  init(client: any UbiquitousKeyValueStoreClient) {
    self.client = client
  }

  func withAccess<Result: Sendable>(
    _ body: (any UbiquitousKeyValueStoreClient) -> Result
  ) -> Result {
    accessLock.lock()
    accessDepth += 1

    let result = body(client)

    accessDepth -= 1
    let ticket: PublicationTicket?
    if accessDepth == 0, !currentPublications.isEmpty {
      let publications = currentPublications
      currentPublications = []
      ticket = enqueue(publications)
    } else {
      ticket = nil
    }
    accessLock.unlock()

    finish(ticket)

    return result
  }

  /// Adds a keyed-value change handler and starts the process-wide store
  /// observation before requesting the initial iCloud synchronization.
  func observeChanges(
    forKey key: String,
    _ receiveChange: @escaping ChangeHandler
  ) -> UbiquitousKeyValueSubscription {
    let registration = withAccess { client in
      let id = UUID()
      changeHandlers[key, default: [:]][id] = receiveChange

      if storeObservation == nil {
        storeObservation = client.observe { [weak self] change in
          self?.receive(change)
        }
      }

      let shouldSynchronize = !hasRequestedInitialSynchronization
      hasRequestedInitialSynchronization = true

      return (id: id, shouldSynchronize: shouldSynchronize)
    }

    if registration.shouldSynchronize {
      _ = withAccess { client in
        client.synchronize()
      }
    }

    return UbiquitousKeyValueSubscription { [weak self] in
      self?.removeChangeHandler(id: registration.id, forKey: key)
    }
  }

  /// Performs one local mutation and then refreshes each wrapper for the key.
  ///
  /// The mutation closure may enqueue the writer's read-back value. That
  /// publication finishes before peer wrappers are refreshed, and no
  /// coordinator lock is held while their graph callbacks run.
  func mutateValue(
    forKey key: String,
    _ mutation: (any UbiquitousKeyValueStoreClient) -> Void
  ) {
    withAccess(mutation)
    deliver(
      UbiquitousKeyValueStoreChange(
        reason: .local,
        changedKeys: [key]
      )
    )
  }

  func publish(_ publication: @escaping @Sendable () -> Void) {
    accessLock.lock()

    if accessDepth > 0 {
      currentPublications.append(publication)
      accessLock.unlock()
      return
    }

    let ticket = enqueue([publication])
    accessLock.unlock()

    finish(ticket)
  }

  private func receive(_ change: UbiquitousKeyValueStoreChange) {
    deliver(change)
  }

  /// Delivers handlers sequentially so a reentrant write completes before the
  /// next peer reloads the current store value.
  private func deliver(_ change: UbiquitousKeyValueStoreChange) {
    accessLock.lock()

    let handlers: [ChangeHandler]
    let usesChangedKeys: Bool
    switch change.reason {
    case .account:
      usesChangedKeys = false
    case .local, .server, .initialSync, .quotaViolation, .unknown:
      usesChangedKeys = true
    }

    if usesChangedKeys, let changedKeys = change.changedKeys {
      handlers = changedKeys.flatMap { key -> [ChangeHandler] in
        guard let handlers = changeHandlers[key] else { return [] }
        return Array(handlers.values)
      }
    } else {
      handlers = changeHandlers.values.flatMap { Array($0.values) }
    }

    accessLock.unlock()

    for handler in handlers {
      handler(change)
    }
  }

  private func removeChangeHandler(id: UUID, forKey key: String) {
    accessLock.lock()
    changeHandlers[key]?[id] = nil
    if changeHandlers[key]?.isEmpty == true {
      changeHandlers[key] = nil
    }

    let observation: UbiquitousKeyValueStoreObservation?
    if changeHandlers.isEmpty {
      observation = storeObservation
      storeObservation = nil
    } else {
      observation = nil
    }

    accessLock.unlock()
    observation?.cancel()
  }

  /// Enqueues a complete access batch while preserving access-lock order.
  /// Must be called while `accessLock` is held.
  private func enqueue(
    _ publications: [@Sendable () -> Void]
  ) -> PublicationTicket {
    publicationCondition.lock()

    nextBatchID &+= 1
    let batch = PublicationBatch(
      id: nextBatchID,
      publications: publications
    )
    pendingBatches.append(batch)

    let shouldDrain: Bool
    if isDraining {
      shouldDrain = false
    } else {
      isDraining = true
      shouldDrain = true
    }

    publicationCondition.unlock()
    return PublicationTicket(id: batch.id, shouldDrain: shouldDrain)
  }

  private func finish(_ ticket: PublicationTicket?) {
    guard let ticket else { return }

    if ticket.shouldDrain {
      drainAsOwner()
    } else if isDrainingOnCurrentThread {
      // A publication callback may synchronously write another value. Drain
      // through that batch without waiting on the current drainer thread.
      drainPublications(until: ticket.id)
    } else {
      publicationCondition.lock()
      while !isCompleted(ticket.id) {
        publicationCondition.wait()
      }
      publicationCondition.unlock()
    }
  }

  private var isDrainingOnCurrentThread: Bool {
    Thread.current.threadDictionary[drainingContextKey] as? Bool == true
  }

  private func drainAsOwner() {
    let threadDictionary = Thread.current.threadDictionary
    threadDictionary[drainingContextKey] = true
    defer { threadDictionary.removeObject(forKey: drainingContextKey) }

    drainPublications(until: nil)
  }

  private func drainPublications(until targetID: UInt64?) {
    while true {
      publicationCondition.lock()

      guard !pendingBatches.isEmpty else {
        if targetID == nil {
          isDraining = false
        }
        publicationCondition.unlock()
        return
      }

      let batch = pendingBatches.removeFirst()
      publicationCondition.unlock()

      for publication in batch.publications {
        publication()
      }

      publicationCondition.lock()
      markCompleted(batch.id)
      publicationCondition.broadcast()
      publicationCondition.unlock()

      if batch.id == targetID {
        return
      }
    }
  }

  /// Must be called while `publicationCondition` is held.
  private func isCompleted(_ id: UInt64) -> Bool {
    id <= completedThroughBatchID || completedOutOfOrderBatchIDs.contains(id)
  }

  /// Must be called while `publicationCondition` is held.
  private func markCompleted(_ id: UInt64) {
    guard id == completedThroughBatchID &+ 1 else {
      completedOutOfOrderBatchIDs.insert(id)
      return
    }

    completedThroughBatchID = id
    while completedOutOfOrderBatchIDs.remove(completedThroughBatchID &+ 1) != nil {
      completedThroughBatchID &+= 1
    }
  }
}

/// A reference-identity cancellation token for one coordinator subscription.
final class UbiquitousKeyValueSubscription: @unchecked Sendable {
  private let lock = NSLock()
  private var cancellation: (@Sendable () -> Void)?

  init(cancellation: @escaping @Sendable () -> Void) {
    self.cancellation = cancellation
  }

  deinit {
    cancel()
  }

  func cancel() {
    lock.lock()
    let cancellation = self.cancellation
    self.cancellation = nil
    lock.unlock()

    cancellation?()
  }
}
