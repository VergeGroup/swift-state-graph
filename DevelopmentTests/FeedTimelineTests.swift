import Testing
@testable import Development

private actor Server {
  enum Failure: Error { case offline, unexpectedCursor }
  let appendStarted = AsyncStream<Void>.makeStream()
  let appendCancelled = AsyncStream<Void>.makeStream()
  private var appendWaiter: CheckedContinuation<Void, Never>?
  private var holdAppend = true
  var appendReads = 0
  var homeReads = 0
  var failNextRefresh = false

  func failRefresh() { failNextRefresh = true }

  func releaseAppend() {
    holdAppend = false
    appendWaiter?.resume()
    appendWaiter = nil
  }

  func page(_ scope: FeedScope, after cursor: String?) async throws -> FeedPage {
    switch (scope, cursor) {
    case (.home, nil):
      if failNextRefresh {
        failNextRefresh = false
        throw Failure.offline
      }
      homeReads += 1
      if homeReads == 1 {
        return FeedPage(rows: [row("a", 1), row("b", 2)], nextCursor: "old")
      }
      return FeedPage(rows: [row("c", 3), row("b", 2, revision: 2)], nextCursor: "new")
    case (.home, "old"):
      appendReads += 1
      appendStarted.continuation.finish()
      // Return the payload even if the transport receives cancellation.
      if holdAppend {
        await withTaskCancellationHandler {
          await withCheckedContinuation { appendWaiter = $0 }
        } onCancel: {
          self.appendCancelled.continuation.finish()
        }
      }
      // The discarded response would overwrite B even with revision-based merging.
      return FeedPage(rows: [row("obsolete", 2, revision: 99)], nextCursor: nil)
    case (.home, "new"):
      return FeedPage(rows: [row("b", 2), row("another-placement", 2)], nextCursor: nil)
    case (.profile, nil):
      return FeedPage(rows: [row("a", 1), row("b", 2)], nextCursor: "profile")
    case (.profile, "profile"):
      return FeedPage(rows: [row("b", 2), row("d", 4)], nextCursor: nil)
    default:
      throw Failure.unexpectedCursor
    }
  }

  private func row(_ placement: String, _ id: Int, revision: Int = 1) -> FeedPage.Row {
    FeedPage.Row(
      placement: placement, postID: id,
      author: .init(id: "m", name: revision == 1 ? "M. Chen" : "Marina Chen"),
      caption: "Post \(id)", likes: revision, revision: revision
    )
  }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct FeedTimelineTests {
  @Test func refreshSupersedesAppendAndPreservesTheProfile() async throws {
    let server = Server()
    let stack = FeedSession { try await server.page($0, after: $1) }.makeStack()
    let home = try await stack.query(FeedQuery(scope: .home))
    #expect(home.entries.map(\.id) == ["a", "b"])
    #expect(home.hasNextPage)
    let profile = try await stack.query(FeedQuery(scope: .profile))
    let retained = try #require(home.entries.last?.post)
    let first = try #require(profile.entries.first?.post)
    #expect(profile.entries.last?.post === retained)
    #expect(first.author === retained.author)
    #expect(first.author.name == "M. Chen")

    let append = Task { try await home.loadNext() }
    for await _ in server.appendStarted.stream {}
    try await home.loadNext()
    #expect(await server.appendReads == 1)

    let refresh = Task { try await home.refresh() }
    for await _ in server.appendCancelled.stream {}
    #expect(home.isLoading)
    #expect(await server.homeReads == 1)
    await server.releaseAppend()
    try await append.value
    try await refresh.value
    #expect(home.entries.map(\.id) == ["c", "b"])
    #expect(retained.likes == 2)
    #expect(first.author.name == "Marina Chen")
    #expect(profile.entries.map(\.id) == ["a", "b"])
    #expect(home.entries.last?.post === retained)

    try await home.loadNext()
    #expect(home.entries.map(\.id) == ["c", "b", "another-placement"])
    #expect(home.entries.last?.post === retained)
    #expect(retained.likes == 2)
    #expect(!home.hasNextPage)
    try await profile.loadNext()
    #expect(profile.entries.map(\.id) == ["a", "b", "d"])
    #expect(retained.likes == 2)
    #expect(first.author.name == "Marina Chen")
  }

  @Test func failedRefreshRetainsThePreviousEntriesAndContinuation() async throws {
    let server = Server()
    let home = try await FeedSession { try await server.page($0, after: $1) }
      .makeStack().query(FeedQuery(scope: .home))
    await server.failRefresh()
    await #expect(throws: Server.Failure.offline) { try await home.refresh() }
    #expect(home.entries.map(\.id) == ["a", "b"])
    #expect(!home.isLoading)
    await server.releaseAppend()
    try await home.loadNext()
    #expect(home.entries.map(\.id) == ["a", "b", "obsolete"])
  }

  @Test func cancellingTheWaiterDiscardsItsLateResponse() async throws {
    let server = Server()
    let home = try await FeedSession { try await server.page($0, after: $1) }
      .makeStack().query(FeedQuery(scope: .home))
    let post = try #require(home.entries.last?.post)
    let append = Task { try await home.loadNext() }
    for await _ in server.appendStarted.stream {}
    append.cancel()
    for await _ in server.appendCancelled.stream {}
    await server.releaseAppend()
    await #expect(throws: CancellationError.self) { try await append.value }
    #expect(home.entries.map(\.id) == ["a", "b"])
    #expect(post.likes == 1)
    #expect(home.hasNextPage)
    #expect(!home.isLoading)
  }
}
