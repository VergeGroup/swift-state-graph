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
/// literal with generic arguments on every evaluation, which costs far more than the
/// registrar call itself.
///
/// Evaluating the literal in each node initializer instead would nearly triple the cost
/// of creating a node, and models create many nodes at once. A process-wide dictionary
/// behind a lock is cheap on one thread, but threads creating nodes concurrently contend
/// on it and each node became several times slower. Each thread therefore keeps its own
/// table, which needs no lock. The price is one literal evaluation per node type on each
/// thread plus the table itself, paid again by a thread that replaces an exited one.
/// Threads creating nodes at the same time still slow down more than a single thread
/// does, though far less than with the shared lock.
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
    let keyPath = NodeObservationKeyPathTable.keyPath(
      for: .init(value: Value.self, kind: .stored)
    ) {
      \NodeObservationRoot<Stored<Value>>.wrappedValue
    }
    // A key is only ever stored with the key path of its own node type.
    return unsafeDowncast(
      keyPath,
      to: (KeyPath<NodeObservationRoot<Stored<Value>>, Void> & Sendable).self
    )
  }

  static func computed<Value>(
    _: Value.Type
  ) -> KeyPath<NodeObservationRoot<Computed<Value>>, Void> & Sendable {
    let keyPath = NodeObservationKeyPathTable.keyPath(
      for: .init(value: Value.self, kind: .computed)
    ) {
      \NodeObservationRoot<Computed<Value>>.wrappedValue
    }
    // A key is only ever stored with the key path of its own node type.
    return unsafeDowncast(
      keyPath,
      to: (KeyPath<NodeObservationRoot<Computed<Value>>, Void> & Sendable).self
    )
  }
}

/// The calling thread's node key paths.
///
/// Only the owning thread reads or writes a table, so it needs no lock. The table lives
/// in raw thread-specific storage rather than an object so that a lookup performs no
/// reference counting. It is destroyed when its thread exits; nodes keep their own
/// references to the key paths they were given.
///
/// It does not use `ThreadLocalValue`, which models values that graph operations install
/// and restore around a scope; this table instead lives as long as its thread.
private struct NodeObservationKeyPathTable {

  enum NodeKind {
    case stored
    case computed
  }

  /// Metadata for `Value` is never deallocated, so its identifier is never reused.
  struct Key: Hashable {
    let value: ObjectIdentifier
    let kind: NodeKind

    init(value: Any.Type, kind: NodeKind) {
      self.value = ObjectIdentifier(value)
      self.kind = kind
    }
  }

  var keyPaths: [Key: AnyKeyPath] = [:]

  /// Returns this thread's key path for `key`, evaluating `makeKeyPath` on first use.
  ///
  /// The lookup is not generic, so callers pay for node type metadata only on a miss.
  static func keyPath(
    for key: Key,
    _ makeKeyPath: () -> AnyKeyPath
  ) -> AnyKeyPath {
    let table = current

    if let cached = table.pointee.keyPaths[key] {
      return cached
    }

    let keyPath = makeKeyPath()
    table.pointee.keyPaths[key] = keyPath
    return keyPath
  }

  private static var current: UnsafeMutablePointer<NodeObservationKeyPathTable> {
    if let pointer = pthread_getspecific(threadSpecificKey) {
      return pointer.assumingMemoryBound(to: NodeObservationKeyPathTable.self)
    }

    let table = UnsafeMutablePointer<NodeObservationKeyPathTable>.allocate(capacity: 1)
    table.initialize(to: NodeObservationKeyPathTable())
    // An unregistered table would be leaked and replaced on every lookup.
    let status = pthread_setspecific(threadSpecificKey, table)
    precondition(status == 0, "Failed to store the node key path table")
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
