@_exported import StateGraph
@_exported import TypedIdentifier

import Foundation
import TypedIdentifier

/// Coordinates mutations across a related set of entity stores.
///
/// Give every ``EntityStore`` in one database the same coordinator to serialize
/// canonical entity selection across tables. The lock is recursive so a store
/// mutation may synchronously import relationships into another coordinated
/// store.
public final class EntityStoreMutationCoordinator: @unchecked Sendable {

  private let lock = NSRecursiveLock()

  public init() {}

  fileprivate func withLock<Result, Failure: Error>(
    _ body: () throws(Failure) -> Result
  ) throws(Failure) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}

/// A graph-observable canonical entity collection.
///
/// `EntityStore` has reference semantics and owns its entity dictionary. Reads
/// observe one stable dictionary value, while mutations are serialized by the
/// supplied ``EntityStoreMutationCoordinator`` and publish one graph update
/// after a successful commit.
public final class EntityStore<T: TypedIdentifiable & Sendable>: Sendable {

  private let mutationCoordinator: EntityStoreMutationCoordinator

  @GraphStored
  private var entities: [T.TypedID: T]

  /// Creates an entity store.
  ///
  /// - Parameters:
  ///   - entities: The initial canonical entities, keyed by typed identifier.
  ///   - mutationCoordinator: The coordinator shared by related entity stores.
  ///     Omitting it creates an independently coordinated store.
  public init(
    entities: [T.TypedID: T] = [:],
    mutationCoordinator: EntityStoreMutationCoordinator = .init()
  ) {
    self.mutationCoordinator = mutationCoordinator
    self.entities = entities
  }

  public func get(by id: T.TypedID) -> T? {
    entities[id]
  }

  public func getAll() -> some Collection<T> {
    entities.values
  }

  public func add(_ entity: T) {
    modifyEntities { entities in
      entities[entity.id] = entity
    }
  }

  public func add(_ newEntities: some Sequence<T>) {
    modifyEntities { entities in
      for entity in newEntities {
        entities[entity.id] = entity
      }
    }
  }

  public func modify(_ id: T.TypedID, _ block: (inout T) -> Void) {
    modifyEntities { entities in
      guard var entity = entities[id] else { return }
      block(&entity)
      entities[id] = entity
    }
  }

  public func filter(_ predicate: (T) -> Bool) -> [T] {
    entities.values.filter(predicate)
  }

  public func update(_ entity: T) {
    modifyEntities { entities in
      entities[entity.id] = entity
    }
  }

  public func delete(_ id: T.TypedID) {
    modifyEntities { entities in
      entities.removeValue(forKey: id)
    }
  }

  public var isEmpty: Bool {
    entities.isEmpty
  }

  public var count: Int {
    entities.count
  }

  public func contains(_ id: T.TypedID) -> Bool {
    entities[id] != nil
  }

  public subscript(_ id: T.TypedID) -> T? {
    get {
      entities[id]
    }
    set {
      modifyEntities { entities in
        entities[id] = newValue
      }
    }
  }

  /// Atomically updates an existing canonical entity or creates and inserts it.
  ///
  /// The coordinator remains locked while `update` or `create` executes, so
  /// concurrent calls for the same identifier converge on one stored entity.
  /// A successful operation publishes one store update. If either closure
  /// throws, the candidate dictionary is not committed and the store does not
  /// publish an update.
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
    try modifyEntities { (entities: inout [T.TypedID: T]) throws(ResultError) -> T in
      if var entity = entities[id] {
        try update(&entity)
        entities[id] = entity
        return entity
      }

      let entity = try create()
      entities[entity.id] = entity
      return entity
    }
  }

  @discardableResult
  private func modifyEntities<Result, Failure: Error>(
    _ body: (inout [T.TypedID: T]) throws(Failure) -> Result
  ) throws(Failure) -> Result {
    try mutationCoordinator.withLock { () throws(Failure) -> Result in
      var candidate = entities
      let result = try body(&candidate)
      entities = candidate
      return result
    }
  }
}
