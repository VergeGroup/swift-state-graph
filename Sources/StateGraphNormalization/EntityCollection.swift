/// Maps a collection's queries and domain mutations to its data source.
public protocol EntityCollectionAdapter: Sendable {

  associatedtype Entity: TypedIdentifiable & Sendable
  associatedtype Query: Hashable & Sendable
  associatedtype Mutation: Sendable

  /// Returns the complete, ordered result for this query.
  func load(_ query: Query) async throws -> [Entity]

  /// Returns the entity changes confirmed by the data source.
  func mutate(_ mutation: Mutation) async throws -> [EntityChange<Entity>]

}

public enum EntityChange<Entity: TypedIdentifiable & Sendable>: Sendable {

  case upsert(Entity)
  case delete(Entity.TypedID)

}

/// Loads query results and applies confirmed mutations to a shared entity store.
public actor EntityCollection<Adapter: EntityCollectionAdapter> {

  public struct Snapshot: Sendable {

    public fileprivate(set) var entities = EntityStore<Adapter.Entity>()
    fileprivate var resultIDs: [Adapter.Query: [Adapter.Entity.TypedID]] = [:]

    public init() {}

    /// Returns nil until the query has loaded, or its rows in server order.
    public func results(for query: Adapter.Query) -> [Adapter.Entity]? {
      resultIDs[query]?.compactMap { entities[$0] }
    }

  }

  public private(set) var snapshot = Snapshot()

  private struct Waiter {
    let id: UInt64
    let continuation: CheckedContinuation<Void, any Error>
  }

  private let adapter: Adapter
  private let onChange: @Sendable (Snapshot) -> Void
  private var isRunning = false
  private var nextWaiterID: UInt64 = 0
  private var waiters: [Waiter] = []

  internal var queuedOperationCount: Int { waiters.count }

  public init(
    adapter: Adapter,
    onChange: @escaping @Sendable (Snapshot) -> Void = { _ in }
  ) {
    self.adapter = adapter
    self.onChange = onChange
  }

  /// Replaces this query's membership while retaining entities shared with other queries.
  public func load(_ query: Adapter.Query) async throws {
    try await acquire()
    defer { release() }
    try Task.checkCancellation()
    let rows = try await adapter.load(query)
    try Task.checkCancellation()

    var seen: Set<Adapter.Entity.TypedID> = []
    snapshot.resultIDs[query] = rows.compactMap { row in
      seen.insert(row.typedID).inserted ? row.typedID : nil
    }
    snapshot.entities.add(rows)
    onChange(snapshot)
  }

  /// Applies the adapter's confirmed changes together. Reload a query to refresh its ordering or membership.
  public func mutate(_ mutation: Adapter.Mutation) async throws {
    try await acquire()
    defer { release() }
    try Task.checkCancellation()
    // A server can confirm a write after the caller cancels its task.
    let changes = try await adapter.mutate(mutation)
    guard !changes.isEmpty else { return }

    var deleted: Set<Adapter.Entity.TypedID> = []
    for change in changes {
      switch change {
      case .upsert(let entity):
        snapshot.entities.add(entity)
      case .delete(let id):
        snapshot.entities.delete(id)
        deleted.insert(id)
      }
    }
    if !deleted.isEmpty {
      for query in snapshot.resultIDs.keys {
        snapshot.resultIDs[query]?.removeAll { deleted.contains($0) }
      }
    }
    onChange(snapshot)
  }

  // An actor can reenter while the adapter awaits I/O. Admit one operation at
  // a time so a response cannot overwrite a later confirmed write or deletion.
  private func acquire() async throws {
    let id = nextWaiterID
    nextWaiterID += 1
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else if isRunning {
          waiters.append(Waiter(id: id, continuation: continuation))
        } else {
          isRunning = true
          continuation.resume()
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  private func cancelWaiter(_ id: UInt64) {
    if let index = waiters.firstIndex(where: { $0.id == id }) {
      waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
  }

  private func release() {
    if waiters.isEmpty {
      isRunning = false
    } else {
      waiters.removeFirst().continuation.resume()
    }
  }

}
