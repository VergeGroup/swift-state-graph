@_exported import StateGraph
@_exported import TypedIdentifier

import TypedIdentifier

/// A value-semantic collection of entities indexed by typed identifiers.
///
/// `EntityStore` deliberately contains only entity storage. It does not
/// coordinate concurrent access or publish graph updates by itself. Store it in
/// a ``Stored`` node, usually through ``GraphStored``, when reads and
/// mutations should participate in a state graph.
///
/// Like other Swift value types, copying an entity store creates an independent
/// logical collection. The underlying dictionary uses copy-on-write storage.
/// Copying a store does not clone reference-type entities contained in it.
public struct EntityStore<T: TypedIdentifiable & Sendable>: Sendable {

  private var entities: [T.TypedID: T]

  /// Creates an entity store.
  ///
  /// - Parameter entities: The initial entities, keyed by typed identifier.
  public init(entities: consuming [T.TypedID: T] = [:]) {
    self.entities = entities
  }

  /// Returns the entity associated with `id`.
  public func get(by id: T.TypedID) -> T? {
    entities[id]
  }

  /// Returns a snapshot of all entities in the store.
  ///
  /// The returned array has independent collection storage. Reference-type
  /// entities in that array are not cloned.
  public func getAll() -> [T] {
    Array(entities.values)
  }

  /// Inserts an entity, replacing an existing entity with the same identifier.
  public mutating func add(_ entity: T) {
    entities[entity.id] = entity
  }

  /// Inserts entities, replacing existing entities with matching identifiers.
  public mutating func add(_ newEntities: some Sequence<T>) {
    for entity in newEntities {
      entities[entity.id] = entity
    }
  }

  /// Mutates the entity associated with `id`, when present.
  ///
  /// For a reference-type entity, this operation does not clone the referenced
  /// object before passing it to `block`.
  public mutating func modify(_ id: T.TypedID, _ block: (inout T) -> Void) {
    guard var entity = entities[id] else { return }
    block(&entity)
    entities[id] = entity
  }

  /// Returns the entities that satisfy `predicate`.
  public func filter(_ predicate: (T) -> Bool) -> [T] {
    entities.values.filter(predicate)
  }

  /// Replaces the entity with the same identifier.
  public mutating func update(_ entity: T) {
    entities[entity.id] = entity
  }

  /// Removes the entity associated with `id`.
  public mutating func delete(_ id: T.TypedID) {
    entities.removeValue(forKey: id)
  }

  /// A Boolean value that indicates whether the store contains no entities.
  public var isEmpty: Bool {
    entities.isEmpty
  }

  /// The number of entities in the store.
  public var count: Int {
    entities.count
  }

  /// Returns whether the store contains an entity associated with `id`.
  public func contains(_ id: T.TypedID) -> Bool {
    entities[id] != nil
  }

  /// Accesses the entity associated with `id`.
  public subscript(_ id: T.TypedID) -> T? {
    get {
      entities[id]
    }
    set {
      entities[id] = newValue
    }
  }

  /// Updates an existing entity or creates and inserts one.
  ///
  /// The dictionary entry is replaced or inserted only after the selected
  /// closure returns successfully. If either closure throws, the entry itself
  /// is not changed.
  ///
  /// The rollback guarantee follows `T`'s semantics. Mutations already applied
  /// through reference storage in an entity are not reverted when `update`
  /// throws.
  ///
  /// - Parameters:
  ///   - id: The identifier used to find an existing entity.
  ///   - update: Updates the existing entity in place.
  ///   - create: Creates the entity when the identifier is not present.
  /// - Returns: The updated or newly inserted entity.
  @discardableResult
  public mutating func updateOrCreate<ResultError: Error>(
    id: T.TypedID,
    update: (inout T) throws(ResultError) -> Void,
    create: () throws(ResultError) -> T
  ) throws(ResultError) -> T {
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
