import StateGraph
import StateGraphNormalization
import Testing

private struct Todo: TypedIdentifiable, Sendable {

  typealias TypedIdentifierRawValue = Int
  let typedID: TypedID
  let title: String

  init(_ id: Int, _ title: String) {
    self.typedID = .init(id)
    self.title = title
  }

}

private struct TodoAdapter: EntityCollectionAdapter {

  enum Query: Hashable { case all, open }
  enum Mutation { case rename, delete }

  let fetch: @Sendable (Query) async throws -> [Todo]
  let persist: @Sendable (Mutation) async throws -> [EntityChange<Todo>]

  func load(_ query: Query) async throws -> [Todo] {
    try await fetch(query)
  }

  func mutate(_ mutation: Mutation) async throws -> [EntityChange<Todo>] {
    try await persist(mutation)
  }

}

private actor TodoServer {

  var rows = [Todo(2, "second"), Todo(1, "first")]

  func load(_ query: TodoAdapter.Query) -> [Todo] {
    switch query {
    case .all: rows
    case .open: Array(rows.suffix(1))
    }
  }

  func replaceRows(_ rows: [Todo]) {
    self.rows = rows
  }

}

struct EntityCollectionTests {

  @Test func queriesShareRowsAndKeepIndependentMembership() async throws {
    let server = TodoServer()
    let adapter = TodoAdapter(fetch: { await server.load($0) }, persist: { mutation in
      switch mutation {
      case .rename: [.upsert(Todo(1, "renamed"))]
      case .delete: [.delete(.init(1))]
      }
    })
    let node = Stored<EntityCollection<TodoAdapter>.Snapshot>(wrappedValue: .init())
    let collection = EntityCollection(adapter: adapter) { node.wrappedValue = $0 }
    let titles = Computed { _ in node.wrappedValue.results(for: .open)?.map(\.title) }

    #expect(titles.wrappedValue == nil)
    try await collection.load(.all)
    try await collection.load(.open)
    #expect(node.wrappedValue.results(for: .all)?.map(\.title) == ["second", "first"])
    #expect(titles.wrappedValue == ["first"])

    try await collection.mutate(.rename)
    #expect(node.wrappedValue.results(for: .all)?.map(\.title) == ["second", "renamed"])
    #expect(titles.wrappedValue == ["renamed"])

    await server.replaceRows([])
    try await collection.load(.all)
    #expect(node.wrappedValue.results(for: .all)?.isEmpty == true)
    #expect(titles.wrappedValue == ["renamed"])

    try await collection.mutate(.delete)
    #expect(titles.wrappedValue == [])
    #expect(node.wrappedValue.entities[.init(1)] == nil)

    await server.replaceRows([Todo(1, "recreated")])
    try await collection.load(.all)
    #expect(titles.wrappedValue == [])
  }

  @Test func rejectedOperationsPreserveConfirmedStateAndCanBeRetried() async throws {
    enum Failure: Error { case rejected }
    let adapter = TodoAdapter(fetch: { query in
      guard query == .all else { throw Failure.rejected }
      return [Todo(1, "first"), Todo(2, "second"), Todo(1, "latest")]
    }, persist: { mutation in
      switch mutation {
      case .rename: throw Failure.rejected
      case .delete: return [.delete(.init(1)), .delete(.init(2))]
      }
    })
    let collection = EntityCollection(adapter: adapter)
    try await collection.load(.all)
    await #expect(throws: Failure.self) { try await collection.load(.open) }
    await #expect(throws: Failure.self) { try await collection.mutate(.rename) }

    let snapshot = await collection.snapshot
    #expect(snapshot.results(for: .open) == nil)
    #expect(snapshot.results(for: .all)?.map(\.title) == ["latest", "second"])
    try await collection.mutate(.delete)
    #expect(await collection.snapshot.entities.isEmpty)
  }

  @Test func overlappingLoadAndWritesApplyInOrderAndSkipCancelledWork() async throws {
    let started = AsyncStream<Void>.makeStream()
    let finish = AsyncStream<Void>.makeStream()
    let adapter = TodoAdapter(fetch: { _ in
      started.continuation.finish()
      for await _ in finish.stream {}
      return [Todo(1, "loaded")]
    }, persist: { mutation in
      switch mutation {
      case .rename:
        Issue.record("Cancelled mutation reached the adapter")
        return []
      case .delete:
        return [.delete(.init(1))]
      }
    })
    let collection = EntityCollection(adapter: adapter)
    let load = Task { try await collection.load(.all) }
    for await _ in started.stream {}
    let cancelled = Task { try await collection.mutate(.rename) }
    let delete = Task { try await collection.mutate(.delete) }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }

    finish.continuation.finish()
    try await load.value
    try await delete.value
    #expect(await collection.snapshot.results(for: .all)?.isEmpty == true)
  }

  @Test func cancelledReadIsDiscardedAndConfirmedWriteIsPublished() async throws {
    let adapter = TodoAdapter(fetch: { _ in
      withUnsafeCurrentTask { $0?.cancel() }
      return [Todo(1, "cancelled read")]
    }, persist: { _ in
      withUnsafeCurrentTask { $0?.cancel() }
      return [.upsert(Todo(1, "confirmed write"))]
    })
    let collection = EntityCollection(adapter: adapter)
    let read = Task { try await collection.load(.all) }
    await #expect(throws: CancellationError.self) { try await read.value }
    #expect(await collection.snapshot.results(for: .all) == nil)

    try await Task { try await collection.mutate(.rename) }.value
    #expect(await collection.snapshot.entities[.init(1)]?.title == "confirmed write")
  }

}
