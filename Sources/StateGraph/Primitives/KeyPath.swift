import Foundation
import Observation

/// A type-specific subject that gives every node registrar a readable property key path.
///
/// Node identity is carried by each node's own `ObservationRegistrar`, so the key path
/// only needs to describe the observed value. For example, a stored integer prints as
/// `\NodeObservationRoot<Stored<Int>>.wrappedValue` instead of embedding a memory address.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
struct NodeObservationRoot<Owner: AnyObject>: Observable, Sendable {

  let wrappedValue: Void = ()
}

/// Supplies each node with its `\NodeObservationRoot<Owner>.wrappedValue` key path.
///
/// Nodes obtain the key path once when they are created and pass the stored value to
/// every Observation call, because those calls sit on the node read path. That code is
/// not specialized for client value types, and the runtime instantiates a key path
/// literal with generic arguments on every evaluation: about 600 ns, far more than the
/// registrar call itself.
///
/// Evaluating the literal in each node initializer instead would nearly triple node
/// creation (about 360 ns to 1,000 ns for `Stored<Int>`), and models create many nodes
/// at once. A process-wide dictionary behind a lock costs about 10 ns per node on one
/// thread, but threads creating nodes concurrently contend on it: with eight threads the
/// wall time per node grew about fivefold. Each thread therefore keeps its own table,
/// which needs no lock and costs one construction per node type on each thread.
///
/// Every instance compares equal and hashes identically, and Observation matches key
/// paths by equality, so a node may keep whichever thread's instance it was given.
///
/// Lookups are keyed by the value type rather than the node type so that a cache hit
/// needs no generic node type metadata, which the runtime would otherwise look up.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
enum NodeObservationKeyPaths {

  static func stored<Value>(
    _: Value.Type
  ) -> KeyPath<NodeObservationRoot<Stored<Value>>, Void> & Sendable {
    let key = NodeObservationKeyPathTable.Key(value: Value.self, owner: .stored)

    if let cached = NodeObservationKeyPathTable.current.pointee.keyPaths[key] {
      // A key is only ever stored with the key path of its own node type.
      return unsafeDowncast(
        cached,
        to: (KeyPath<NodeObservationRoot<Stored<Value>>, Void> & Sendable).self
      )
    }

    let keyPath: KeyPath<NodeObservationRoot<Stored<Value>>, Void> & Sendable =
      \NodeObservationRoot<Stored<Value>>.wrappedValue
    NodeObservationKeyPathTable.current.pointee.keyPaths[key] = keyPath
    return keyPath
  }

  static func computed<Value>(
    _: Value.Type
  ) -> KeyPath<NodeObservationRoot<Computed<Value>>, Void> & Sendable {
    let key = NodeObservationKeyPathTable.Key(value: Value.self, owner: .computed)

    if let cached = NodeObservationKeyPathTable.current.pointee.keyPaths[key] {
      // A key is only ever stored with the key path of its own node type.
      return unsafeDowncast(
        cached,
        to: (KeyPath<NodeObservationRoot<Computed<Value>>, Void> & Sendable).self
      )
    }

    let keyPath: KeyPath<NodeObservationRoot<Computed<Value>>, Void> & Sendable =
      \NodeObservationRoot<Computed<Value>>.wrappedValue
    NodeObservationKeyPathTable.current.pointee.keyPaths[key] = keyPath
    return keyPath
  }
}

/// The calling thread's node key paths.
///
/// Only the owning thread reads or writes a table, so it needs no lock. The table lives
/// in raw thread-specific storage rather than an object so that a lookup performs no
/// reference counting. It is destroyed when its thread exits; nodes keep their own
/// references to the key paths they were given.
private struct NodeObservationKeyPathTable {

  enum Owner {
    case stored
    case computed
  }

  /// Value type metadata is never deallocated, so an identifier is never reused.
  struct Key: Hashable {
    let value: ObjectIdentifier
    let owner: Owner

    init(value: Any.Type, owner: Owner) {
      self.value = ObjectIdentifier(value)
      self.owner = owner
    }
  }

  var keyPaths: [Key: AnyKeyPath] = [:]

  static var current: UnsafeMutablePointer<NodeObservationKeyPathTable> {
    if let pointer = pthread_getspecific(threadSpecificKey) {
      return pointer.assumingMemoryBound(to: NodeObservationKeyPathTable.self)
    }

    let table = UnsafeMutablePointer<NodeObservationKeyPathTable>.allocate(capacity: 1)
    table.initialize(to: NodeObservationKeyPathTable())
    pthread_setspecific(threadSpecificKey, table)
    return table
  }

  private static let threadSpecificKey: pthread_key_t = {
    var key = pthread_key_t()
    let status = pthread_key_create(&key) { pointer in
      let table = pointer.assumingMemoryBound(to: NodeObservationKeyPathTable.self)
      table.deinitialize(count: 1)
      table.deallocate()
    }
    precondition(status == 0, "Failed to create the node key path table key")
    return key
  }()
}
