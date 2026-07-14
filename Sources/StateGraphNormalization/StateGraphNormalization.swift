@_exported import StateGraph
@_exported import TypedIdentifier

import Foundation
import TypedIdentifier

/// Serializes access across a related set of entity stores.
///
/// Give every ``EntityStore`` in one database the same coordinator to protect
/// canonical entity lookup and mutation across tables. The lock is recursive
/// because an entity import may synchronously access another coordinated store.
public final class EntityStoreCoordinator: Sendable {

  fileprivate let lock = NSRecursiveLock()

  public init() {}
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
    coordinator.lock.lock()
    defer { coordinator.lock.unlock() }
    return try body()
  }

  @discardableResult
  private func mutate<Result, Failure: Error>(
    _ body: () throws(Failure) -> Result
  ) throws(Failure) -> Result {
    try withLock { () throws(Failure) -> Result in
      let result = try body()
      publishMutation()
      return result
    }
  }

  private func trackAccess() {
    _ = graphRevision.wrappedValue
  }

  private func publishMutation() {
    let revision = table.advanceRevision()
    graphRevision.wrappedValue = revision
  }
}
