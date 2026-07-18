import Foundation

/// Serializes UserDefaults operations and synchronously publishes graph updates
/// in access order after releasing the access lock.
final class UserDefaultsAccessCoordinator: @unchecked Sendable {

  private struct PublicationBatch: Sendable {
    let id: UInt64
    let publications: [@Sendable () -> Void]
  }

  private struct PublicationTicket {
    let id: UInt64
    let shouldDrain: Bool
  }

  static let shared = UserDefaultsAccessCoordinator()

  private let accessLock = NSRecursiveLock()
  private let publicationCondition = NSCondition()
  private let drainingContextKey =
    "org.vergegroup.state-graph.user-defaults-publication-drainer"

  private var accessDepth = 0
  private var currentPublications: [@Sendable () -> Void] = []

  private var nextBatchID: UInt64 = 0
  private var completedThroughBatchID: UInt64 = 0
  private var completedOutOfOrderBatchIDs: Set<UInt64> = []
  private var isDraining = false
  private var pendingBatches: [PublicationBatch] = []

  func withAccess<Result>(_ body: () -> Result) -> Result {
    accessLock.lock()
    accessDepth += 1

    let result = body()

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
