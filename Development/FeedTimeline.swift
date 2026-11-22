import StateGraph
import StateGraphAsyncDataStore
import StateGraphNormalization
import os

enum FeedScope: Sendable {
  case home
  case profile
}

struct FeedQuery: Query {
  typealias Output = FeedTimeline
  let scope: FeedScope
}

/// A ranked page from the service. A placement and the post it presents have separate IDs.
struct FeedPage: Sendable {
  struct Author: Sendable {
    let id: String
    let name: String
  }

  struct Row: Sendable {
    let placement: String
    var reason: String? = nil
    let postID: Int
    let author: Author
    let caption: String
    let likes: Int
    // The service stamps all fields in a row with the snapshot revision they came from.
    let revision: Int
  }

  let rows: [Row]
  let nextCursor: String?
}

final class FeedAuthor: TypedIdentifiable, Sendable {
  typealias TypedIdentifierRawValue = String
  let typedID: TypedID
  @GraphStored var name: String
  @GraphStored var revision: Int

  @InitAndUpdate
  init(payload: FeedPage.Author, revision: Int) {
    #onInit { self.typedID = .init(payload.id) }
    self.name = payload.name
    self.revision = revision
  }
}

final class FeedPost: TypedIdentifiable, Sendable {
  typealias TypedIdentifierRawValue = Int
  let typedID: TypedID
  @GraphStored var author: FeedAuthor
  @GraphStored var caption: String
  @GraphStored var likes: Int
  @GraphStored var revision: Int

  @InitAndUpdate
  init(row: FeedPage.Row, author: FeedAuthor) {
    #onInit { self.typedID = .init(row.postID) }
    self.author = author
    self.caption = row.caption
    self.likes = row.likes
    self.revision = row.revision
  }
}

@MainActor
final class FeedSession {
  let fetch: @Sendable (FeedScope, String?) async throws -> FeedPage
  private var authors = EntityStore<FeedAuthor>()
  private(set) var posts = EntityStore<FeedPost>()

  init(fetch: @escaping @Sendable (FeedScope, String?) async throws -> FeedPage) {
    self.fetch = fetch
  }

  func merge(_ row: FeedPage.Row) {
    let author = authors.updateOrCreate(
      id: .init(row.author.id),
      update: {
        if row.revision > $0.revision { $0.update(payload: row.author, revision: row.revision) }
      },
      create: { FeedAuthor(payload: row.author, revision: row.revision) }
    )
    posts.updateOrCreate(
      id: .init(row.postID),
      update: {
        if row.revision > $0.revision { $0.update(row: row, author: author) }
      },
      create: { FeedPost(row: row, author: author) }
    )
  }

  func makeStack() -> QueryStack<FeedSession> {
    var stack = QueryStack(dependencies: self)
    stack.register(FeedQuery.self) { query, session in
      let timeline = await FeedTimeline(scope: query.scope, session: session)
      try await timeline.refresh()
      return timeline
    }
    return stack
  }
}

@MainActor
final class FeedTimeline {
  struct Entry: Identifiable {
    let id: String
    let reason: String?
    let post: FeedPost
  }

  private struct State {
    struct Placement {
      let id: String
      let reason: String?
      let postID: FeedPost.TypedID
    }

    var placements: [Placement] = []
    var nextCursor: String?
  }

  private enum Operation {
    case loadNext
    case refresh
  }

  private struct Loader: AsyncDataStoreHeader {
    let scope: FeedScope
    let session: FeedSession

    typealias Value = State

    static func receive(action: Request, header: Self, context: AsyncDataStore<Self>.Context) async {
      let cursor: String?
      switch action.operation {
      case .loadNext:
        guard let next = context.value.nextCursor else { return }
        cursor = next
      case .refresh:
        cursor = nil
      }

      do {
        let page = try await action.fetch { try await header.session.fetch(header.scope, cursor) }
        try action.checkCallerCancellation()
        withGraphTransaction {
          let accepted = context.update { state in
            if cursor == nil { state.placements.removeAll() }
            var seen = Set(state.placements.map(\.id))
            for row in page.rows where seen.insert(row.placement).inserted {
              state.placements.append(.init(
                id: row.placement, reason: row.reason, postID: .init(row.postID)
              ))
            }
            state.nextCursor = page.nextCursor
          }
          guard accepted else { return }
          for row in page.rows { header.session.merge(row) }
        }
      } catch {
        if !Task.isCancelled { action.failure = error }
      }
    }
  }

  // sendAndWait runs the action in the store's task. Tie this call's transport and
  // error to its own waiter so cancelling one caller cannot cancel a newer refresh.
  @MainActor
  private final class Request {
    let operation: Operation
    var failure: (any Error)?
    private enum Transport {
      case waiting
      case fetching(Task<FeedPage, any Error>)
      case cancelled
    }
    private nonisolated let transport = OSAllocatedUnfairLock(initialState: Transport.waiting)

    init(_ operation: Operation) { self.operation = operation }

    func checkCallerCancellation() throws {
      try transport.withLock {
        if case .cancelled = $0 { throw CancellationError() }
      }
    }

    nonisolated func cancel() {
      let previous = transport.withLock {
        let previous = $0
        $0 = .cancelled
        return previous
      }
      if case .fetching(let task) = previous { task.cancel() }
    }

    func fetch(_ body: @escaping @Sendable () async throws -> FeedPage) async throws -> FeedPage {
      let task = try transport.withLock { state in
        guard case .waiting = state else { throw CancellationError() }
        let task = Task { try await body() }
        state = .fetching(task)
        return task
      }
      return try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
    }
  }

  private let store: AsyncDataStore<Loader>
  var entries: [Entry] {
    store.value.placements.compactMap { placement in
      guard let post = store.header.session.posts[placement.postID] else { return nil }
      return Entry(id: placement.id, reason: placement.reason, post: post)
    }
  }

  var hasNextPage: Bool { store.value.nextCursor != nil }
  var isLoading: Bool {
    if case .running = store.phase { return true }
    return false
  }

  init(scope: FeedScope, session: FeedSession) {
    store = AsyncDataStore(header: Loader(scope: scope, session: session), initial: State())
  }

  func refresh() async throws { try await send(.refresh, mode: .dropCurrent) }
  func loadNext() async throws { try await send(.loadNext, mode: .discard) }

  private func send(_ operation: Operation, mode: AsyncDataStoreTaskMode) async throws {
    try Task.checkCancellation()
    let request = Request(operation)
    await withTaskCancellationHandler {
      await store.sendAndWait(action: request, mode: mode)
    } onCancel: {
      request.cancel()
    }
    try Task.checkCancellation()
    if let failure = request.failure { throw failure }
  }
}
