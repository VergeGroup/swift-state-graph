@_exported import StateGraph
@_exported import TypedIdentifier

import TypedIdentifier

public struct EntityStore<T: TypedIdentifiable & Sendable>: Sendable {
  private var entities: [T.TypedID : T]
  
  public init(entities: [T.TypedID: T] = [:]) {
    self.entities = entities
  }
  
  public func get(by id: T.TypedID) -> T? {
    return entities[id]
  }
  
  public func getAll() -> some Collection<T> {
    return entities.values
  }
  
  public mutating func add(_ entity: T) {
    entities[entity.id] = entity
  }

  public mutating func add(_ entities: some Sequence<T>) {
    for entity in entities {
      self.add(entity)
    }
  }

  public mutating func modify(_ id: T.TypedID, _ block: (inout T) -> Void) {
    if var entity = entities[id] {
      block(&entity)
      entities[id] = entity
    }
  }
  
  public func filter(_ predicate: (T) -> Bool) -> [T] {
    return entities.values.filter(predicate)
  }
  
  public mutating func update(_ entity: T) {
    entities[entity.id] = entity
  }
  
  public mutating func delete(_ id: T.TypedID) {
    entities.removeValue(forKey: id)
  }
  
  public var isEmpty: Bool {
    return entities.isEmpty
  }
  
  public var count: Int {
    return entities.count
  }
  
  public func contains(_ id: T.TypedID) -> Bool {
    return entities[id] != nil
  }
    
  public subscript(_ id: T.TypedID) -> T? {
    get {
      return entities[id]
    }
    set {
      if let newValue = newValue {
        entities[id] = newValue
      } else {
        entities.removeValue(forKey: id)
      }
    }
  }    
}
