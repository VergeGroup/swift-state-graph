import StateGraph
import StateGraphNormalization

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
  private var posts = EntityStore<FeedPost>()

  init(fetch: @escaping @Sendable (FeedScope, String?) async throws -> FeedPage) {
    self.fetch = fetch
  }

  func merge(_ row: FeedPage.Row) -> FeedPost {
    let author = authors.updateOrCreate(
      id: .init(row.author.id),
      update: {
        if row.revision > $0.revision { $0.update(payload: row.author, revision: row.revision) }
      },
      create: { FeedAuthor(payload: row.author, revision: row.revision) }
    )
    return posts.updateOrCreate(
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

  private let scope: FeedScope
  private let session: FeedSession
  @GraphStored private var nextCursor: String?
  private var generation = 0
  @GraphStored private(set) var entries: [Entry] = []
  @GraphStored private(set) var isLoading = false
  var hasNextPage: Bool { nextCursor != nil }

  init(scope: FeedScope, session: FeedSession) {
    self.scope = scope
    self.session = session
    nextCursor = nil
  }

  func refresh() async throws {
    generation += 1
    try await load(after: nil)
  }

  func loadNext() async throws {
    guard !isLoading, let nextCursor else { return }
    try await load(after: nextCursor)
  }

  private func load(after cursor: String?) async throws {
    let request = generation
    isLoading = true
    defer { if request == generation { isLoading = false } }

    let page: FeedPage
    do {
      page = try await session.fetch(scope, cursor)
    } catch {
      guard request == generation else { return }
      throw error
    }
    // A refresh supersedes an outstanding append, including its writes to shared posts.
    guard request == generation else { return }
    try Task.checkCancellation()
    withGraphTransaction {
      var result = cursor == nil ? [] : entries
      var seen = Set(result.map(\.id))
      for row in page.rows {
        let post = session.merge(row)
        if seen.insert(row.placement).inserted {
          result.append(Entry(id: row.placement, reason: row.reason, post: post))
        }
      }
      entries = result
      nextCursor = page.nextCursor
    }
  }
}
