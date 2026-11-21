import StateGraphNormalization
import Testing

nonisolated private struct Todo: TypedIdentifiable, Sendable {
  typealias TypedIdentifierRawValue = Int
  let typedID: TypedID
  let title: String
}

private struct TodoByID: Query {
  typealias Output = Todo?
  let id: Todo.TypedID
}

private struct OpenTodos: Query {
  typealias Output = OpenTodoList
  let projectID: Int
}

private struct TodoPage: Sendable {
  let rows: [Todo]
  let nextCursor: String?
}

private protocol TodoAPI: Sendable {
  func todo(id: Todo.TypedID) async throws -> Todo?
  func openTodos(projectID: Int, after cursor: String?) async throws -> TodoPage
}

@MainActor
private final class TodoData {
  let api: any TodoAPI
  var entities = EntityStore<Todo>()

  init(api: any TodoAPI) {
    self.api = api
  }

  func todo(by id: Todo.TypedID) async throws -> Todo? {
    if let cached = entities[id] { return cached }
    try Task.checkCancellation()
    let row = try await api.todo(id: id)
    try Task.checkCancellation()
    if let row { entities.add(row) }
    return entities[id]
  }
}

@MainActor
private final class OpenTodoList {
  enum LoadError: Error { case alreadyLoading }

  private let data: TodoData
  private let projectID: Int
  private var cursor: String?
  private var seen: Set<Todo.TypedID> = []
  private var ids: [Todo.TypedID] = []
  private(set) var isLoading = false
  private(set) var hasNextPage = true

  var rows: [Todo] { ids.compactMap { data.entities[$0] } }

  init(projectID: Int, data: TodoData) {
    self.projectID = projectID
    self.data = data
  }

  func loadNext() async throws {
    guard hasNextPage else { return }
    guard !isLoading else { throw LoadError.alreadyLoading }
    isLoading = true
    defer { isLoading = false }

    try Task.checkCancellation()
    let page = try await data.api.openTodos(projectID: projectID, after: cursor)
    try Task.checkCancellation()
    data.entities.add(page.rows)
    for row in page.rows where seen.insert(row.typedID).inserted {
      ids.append(row.typedID)
    }
    cursor = page.nextCursor
    hasNextPage = cursor != nil
  }
}

@MainActor
private func makeStack(api: any TodoAPI) -> QueryStack<TodoData> {
  var stack = QueryStack(dependencies: TodoData(api: api))
  stack.register(TodoByID.self) { query, data in
    try await data.todo(by: query.id)
  }
  stack.register(OpenTodos.self) { query, data in
    let list = await OpenTodoList(projectID: query.projectID, data: data)
    try await list.loadNext()
    return list
  }
  return stack
}

private actor TestAPI: TodoAPI {
  enum Failure: Error { case offline }
  var lookups: [Todo.TypedID] = []
  var cursors: [String?] = []
  var projects: [Int] = []
  var failNext = false
  let beforePage: @Sendable (String?) async -> Void

  init(beforePage: @escaping @Sendable (String?) async -> Void = { _ in }) {
    self.beforePage = beforePage
  }

  func failNextPage() { failNext = true }

  func todo(id: Todo.TypedID) -> Todo? {
    lookups.append(id)
    return id.raw == 1 ? Todo(typedID: id, title: "detail") : nil
  }

  func openTodos(projectID: Int, after cursor: String?) async throws -> TodoPage {
    projects.append(projectID)
    cursors.append(cursor)
    await beforePage(cursor)
    if failNext {
      failNext = false
      throw Failure.offline
    }
    switch cursor {
    case nil:
      return TodoPage(rows: [Todo(typedID: .init(1), title: "first")], nextCursor: "a")
    case "a":
      return TodoPage(rows: [], nextCursor: "b")
    case "b":
      return TodoPage(rows: [
        Todo(typedID: .init(2), title: "second"),
        Todo(typedID: .init(1), title: "updated"),
      ], nextCursor: nil)
    default:
      Issue.record("Unexpected cursor")
      throw Failure.offline
    }
  }
}

@MainActor
struct QueryStackTests {

  @Test func detailAndPaginatedListResolveThroughOneStore() async throws {
    let api = TestAPI()
    let stack = makeStack(api: api)
    let query = TodoByID(id: .init(1))
    let detail: Todo? = try await stack.resolve(query)
    #expect(detail?.title == "detail")

    let list: OpenTodoList = try await stack.resolve(OpenTodos(projectID: 42))
    #expect(list.rows.map(\.title) == ["first"])
    #expect(try await stack.resolve(query)?.title == "first")

    await api.failNextPage()
    await #expect(throws: TestAPI.Failure.self) { try await list.loadNext() }
    #expect(list.rows.map(\.title) == ["first"])
    try await list.loadNext()
    #expect(list.hasNextPage)
    try await list.loadNext()
    #expect(!list.hasNextPage)
    #expect(list.rows.map(\.title) == ["updated", "second"])
    #expect(try await stack.resolve(query)?.title == "updated")
    try await list.loadNext()
    #expect(await api.cursors == [nil, "a", "a", "b"])
    #expect(await api.projects == [42, 42, 42, 42])
    #expect(try await stack.resolve(TodoByID(id: .init(2)))?.title == "second")
    #expect(try await stack.resolve(TodoByID(id: .init(3))) == nil)
    #expect(await api.lookups == [.init(1), .init(3)])
  }

  @Test func overlappingAndCancelledReadsKeepTheCurrentPage() async throws {
    let started = AsyncStream<Void>.makeStream()
    let resume = AsyncStream<Void>.makeStream()
    let api = TestAPI { cursor in
      if cursor == "a" {
        started.continuation.finish()
        for await _ in resume.stream {}
      }
    }
    let stack = makeStack(api: api)
    let list = try await stack.resolve(OpenTodos(projectID: 42))
    let read = Task { try await list.loadNext() }
    for await _ in started.stream {}
    await #expect(throws: OpenTodoList.LoadError.alreadyLoading) { try await list.loadNext() }
    read.cancel()
    resume.continuation.finish()
    await #expect(throws: CancellationError.self) { try await read.value }
    #expect(list.rows.map(\.title) == ["first"])
    #expect(!list.isLoading)
    try await list.loadNext()
    #expect(await api.cursors == [nil, "a", "a"])
  }

  @Test func dispatchUsesQueryTypeEvenWhenOutputsMatch() async throws {
    struct First: Query { typealias Output = String }
    struct Second: Query { typealias Output = String }
    var stack = QueryStack(dependencies: "fixture")
    stack.register(First.self) { _, prefix in prefix + " one" }
    let firstOnly = stack
    stack.register(Second.self) { _, prefix in prefix + " two" }
    #expect(try await stack.resolve(First()) == "fixture one")
    #expect(try await stack.resolve(Second()) == "fixture two")
    do {
      _ = try await firstOnly.resolve(Second())
      Issue.record("Resolved an unregistered query")
    } catch let error as QueryStack<String>.MissingResolver {
      #expect(ObjectIdentifier(error.queryType) == ObjectIdentifier(Second.self))
    }
  }

}
