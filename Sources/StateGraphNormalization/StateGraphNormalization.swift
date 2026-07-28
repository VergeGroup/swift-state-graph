@_exported import StateGraph
@_exported import TypedIdentifier

import Foundation
import TypedIdentifier

/// Serializes access and graph publication across a related set of entity stores.
///
/// Give every ``EntityStore`` in one database the same coordinator to protect
/// canonical entity lookup and mutation across tables. The lock is recursive
/// because an entity import may synchronously access another coordinated store.
///
/// Graph updates are queued while coordinated access is active, then published
/// synchronously after the outermost access releases the database lock.
public final class EntityStoreCoordinator: @unchecked Sendable {

  private struct PublicationBatch: Sendable {
    let id: UInt64
    let publications: [@Sendable () -> Void]
  }

  private struct PublicationTicket {
    let id: UInt64
    let shouldDrain: Bool
  }

  private let accessLock = NSRecursiveLock()
  private let publicationCondition = NSCondition()
  private let drainingContextKey =
    "org.vergegroup.state-graph.entity-store-publication.\(UUID().uuidString)"

  private var accessDepth = 0
  private var currentPublications: [@Sendable () -> Void] = []

  private var nextBatchID: UInt64 = 0
  private var completedThroughBatchID: UInt64 = 0
  private var completedOutOfOrderBatchIDs: Set<UInt64> = []
  private var isDraining = false
  private var pendingBatches: [PublicationBatch] = []

  public init() {}

  @discardableResult
  fileprivate func withAccess<Result, Failure: Error>(
    _ body: () throws(Failure) -> Result
  ) throws(Failure) -> Result {
    accessLock.lock()
    accessDepth += 1

    defer {
      let ticket = endAccess()
      finish(ticket)
    }

    return try body()
  }

  /// Adds a graph update to the current coordinated access.
  ///
  /// This method must be called from inside ``withAccess(_:)``.
  fileprivate func enqueuePublication(
    _ publication: @escaping @Sendable () -> Void
  ) {
    precondition(accessDepth > 0)
    currentPublications.append(publication)
  }

  /// Ends one recursive access level and enqueues the complete outermost batch.
  private func endAccess() -> PublicationTicket? {
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
    return ticket
  }

  /// Enqueues a publication batch while preserving database access order.
  ///
  /// This method must be called while `accessLock` is held.
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
      // A graph callback may synchronously mutate another coordinated store.
      // Drain through that mutation without waiting on the current drainer.
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

  /// Returns whether a publication batch finished, with the condition held.
  private func isCompleted(_ id: UInt64) -> Bool {
    id <= completedThroughBatchID || completedOutOfOrderBatchIDs.contains(id)
  }

  /// Records a completed batch while preserving a contiguous completion prefix.
  ///
  /// This method must be called while `publicationCondition` is held.
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

/// A uniquely owned canonical entity table.
///
/// `EntityTable` is deliberately unsynchronized. ``EntityStore`` acquires its
/// coordinator before beginning every borrow or exclusive access to this value.
/// Keeping the dictionary inline avoids both an escaping copy and a second heap
/// storage object.
private struct EntityTable<T: TypedIdentifiable & Sendable>: ~Copyable {

  private var entities: [T.TypedID: T]
  private var revision: UInt64 = 0

  init(entities: consuming [T.TypedID: T]) {
    self.entities = entities
  }

  borrowing func get(by id: T.TypedID) -> T? {
    entities[id]
  }

  borrowing func getAll() -> [T] {
    Array(entities.values)
  }

  borrowing func filter(_ predicate: (T) -> Bool) -> [T] {
    entities.values.filter(predicate)
  }

  var isEmpty: Bool {
    entities.isEmpty
  }

  var count: Int {
    entities.count
  }

  borrowing func contains(_ id: T.TypedID) -> Bool {
    entities[id] != nil
  }

  mutating func set(_ entity: T?, for id: T.TypedID) {
    entities[id] = entity
  }

  @discardableResult
  mutating func advanceRevision() -> UInt64 {
    revision &+= 1
    return revision
  }
}

/// A graph-observable canonical entity collection.
///
/// `EntityStore` has reference semantics and owns one noncopyable entity table.
/// Every table access begins after the supplied ``EntityStoreCoordinator`` is
/// locked. Successful mutations update the table in place, end their exclusive
/// access, and then publish one graph update.
public final class EntityStore<T: TypedIdentifiable & Sendable>: Sendable {

  private let coordinator: EntityStoreCoordinator
  private let graphRevision: Stored<UInt64>

  /// Mutable table storage guarded by `coordinator`.
  ///
  /// Every access must begin inside ``withLock(_:)``. The unsafe annotation is
  /// limited to this property so `EntityStore` keeps checked `Sendable`
  /// conformance for all other state.
  nonisolated(unsafe) private var table: EntityTable<T>

  /// Creates an entity store.
  ///
  /// - Parameters:
  ///   - entities: The initial canonical entities, keyed by typed identifier.
  ///   - coordinator: The coordinator shared by related entity stores.
  ///     Omitting it creates an independently coordinated store.
  public init(
    entities: consuming [T.TypedID: T] = [:],
    coordinator: EntityStoreCoordinator = .init()
  ) {
    self.coordinator = coordinator
    self.graphRevision = .init(name: "EntityStore.revision", wrappedValue: 0)
    self.table = .init(entities: entities)
  }

  public func get(by id: T.TypedID) -> T? {
    withLock {
      trackAccess()
      return table.get(by: id)
    }
  }

  /// Returns an independent snapshot of the current canonical entities.
  public func getAll() -> [T] {
    withLock {
      trackAccess()
      return table.getAll()
    }
  }

  public func add(_ entity: T) {
    mutate {
      table.set(entity, for: entity.id)
    }
  }

  public func add(_ newEntities: some Sequence<T>) {
    mutate {
      for entity in newEntities {
        table.set(entity, for: entity.id)
      }
    }
  }

  public func modify(_ id: T.TypedID, _ block: (inout T) -> Void) {
    mutate {
      guard var entity = table.get(by: id) else { return }
      block(&entity)
      table.set(entity, for: id)
    }
  }

  public func filter(_ predicate: (T) -> Bool) -> [T] {
    withLock {
      trackAccess()
      return table.filter(predicate)
    }
  }

  public func update(_ entity: T) {
    mutate {
      table.set(entity, for: entity.id)
    }
  }

  public func delete(_ id: T.TypedID) {
    mutate {
      table.set(nil, for: id)
    }
  }

  public var isEmpty: Bool {
    withLock {
      trackAccess()
      return table.isEmpty
    }
  }

  public var count: Int {
    withLock {
      trackAccess()
      return table.count
    }
  }

  public func contains(_ id: T.TypedID) -> Bool {
    withLock {
      trackAccess()
      return table.contains(id)
    }
  }

  public subscript(_ id: T.TypedID) -> T? {
    get {
      withLock {
        trackAccess()
        return table.get(by: id)
      }
    }
    set {
      mutate {
        table.set(newValue, for: id)
      }
    }
  }

  /// Atomically updates an existing canonical entity or creates and inserts it.
  ///
  /// The coordinator remains locked while `update` or `create` executes, so
  /// concurrent calls for the same identifier converge on one stored entity.
  /// A successful operation publishes one store update. If either closure
  /// throws, the entity table is not mutated and the store does not publish an
  /// update.
  ///
  /// The rollback guarantee follows `T`'s semantics. Mutations already applied
  /// to a reference-type entity are not reverted when `update` throws.
  ///
  /// - Parameters:
  ///   - id: The identifier used to find an existing canonical entity.
  ///   - update: Updates the existing entity in place.
  ///   - create: Creates the entity when the identifier is not present.
  /// - Returns: The updated or newly inserted canonical entity.
  @discardableResult
  public func updateOrCreate<ResultError: Error>(
    id: T.TypedID,
    update: (inout T) throws(ResultError) -> Void,
    create: () throws(ResultError) -> T
  ) throws(ResultError) -> T {
    try mutate { () throws(ResultError) -> T in
      if var entity = table.get(by: id) {
        try update(&entity)
        table.set(entity, for: id)
        return entity
      }

      let entity = try create()
      table.set(entity, for: entity.id)
      return entity
    }
  }

  @discardableResult
  private func withLock<Result, Failure: Error>(
    _ body: () throws(Failure) -> Result
  ) throws(Failure) -> Result {
    try coordinator.withAccess(body)
  }

  @discardableResult
  private func mutate<Result, Failure: Error>(
    _ body: () throws(Failure) -> Result
  ) throws(Failure) -> Result {
    try withLock { () throws(Failure) -> Result in
      let result = try body()
      let revision = table.advanceRevision()

      coordinator.enqueuePublication { [graphRevision] in
        graphRevision.wrappedValue = revision
      }

      return result
    }
  }

  private func trackAccess() {
    _ = graphRevision.wrappedValue
  }

}
