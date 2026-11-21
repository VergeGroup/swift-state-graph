import StateGraphNormalization
import SwiftUI

/// The fixture represents the remote service. Clients receive only the requested page.
private actor FeedDemoServer {
  private var homeReads = 0

  func page(for scope: FeedScope, after cursor: String?) async throws -> FeedPage {
    if scope == .home && cursor == nil { homeReads += 1 }
    let marina = FeedPage.Author(id: "marina", name: "Marina Chen")
    let sol = FeedPage.Author(id: "sol", name: "Sol Rivera")
    let posts = [
      row("tide", 1, marina, "The tide pools were still at sunrise.", 14),
      row("ferry", 2, marina, "Last ferry back from the islands.", 28 + homeReads),
      row("studio", 3, sol, "Fresh prints drying in the studio.", 9),
      row("map", 4, marina, "A new trail for next weekend.", 21),
    ]

    let page: FeedPage
    switch (scope, cursor) {
    case (.home, nil) where homeReads.isMultiple(of: 2):
      var suggested = posts[2]
      suggested.reason = "Suggested for you"
      page = FeedPage(rows: [suggested, posts[1]], nextCursor: "studio-walk")
    case (.home, nil):
      page = FeedPage(rows: [posts[0], posts[1]], nextCursor: "shore-walk")
    case (.home, "shore-walk"):
      page = FeedPage(rows: [posts[2], posts[3]], nextCursor: nil)
    case (.home, "studio-walk"):
      page = FeedPage(rows: [posts[3]], nextCursor: nil)
    case (.profile, nil):
      page = FeedPage(rows: [posts[1], posts[0]], nextCursor: "field-notes")
    case (.profile, "field-notes"):
      page = FeedPage(rows: [posts[3]], nextCursor: nil)
    default:
      throw URLError(.badServerResponse)
    }
    // Keep an append in flight long enough to pull to refresh before it returns.
    try await Task.sleep(for: cursor == nil ? .milliseconds(200) : .seconds(2))
    return page
  }

  private func row(
    _ placement: String, _ id: Int, _ author: FeedPage.Author, _ caption: String, _ likes: Int
  ) -> FeedPage.Row {
    FeedPage.Row(
      placement: placement, postID: id, author: author,
      caption: caption, likes: likes, revision: homeReads
    )
  }
}

struct FeedDemoView: View {
  @State private var stack: QueryStack<FeedSession>
  @State private var scope = FeedScope.home
  @State private var timelines: [FeedScope: FeedTimeline] = [:]
  @State private var errors: [FeedScope: String] = [:]

  init() {
    let server = FeedDemoServer()
    _stack = State(initialValue: FeedSession { try await server.page(for: $0, after: $1) }.makeStack())
  }

  var body: some View {
    VStack {
      Picker("Timeline", selection: $scope) {
        Text("Home").tag(FeedScope.home)
        Text("Marina’s profile").tag(FeedScope.profile)
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)

      List {
        if let message = errors[scope] {
          Text(message).foregroundStyle(.secondary)
        }
        if let timeline = timelines[scope] {
          ForEach(timeline.entries) { entry in
            NavigationLink {
              FeedPostDetail(post: entry.post)
            } label: {
              VStack(alignment: .leading, spacing: 6) {
                if let reason = entry.reason {
                  Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                Text(entry.post.author.name).font(.headline)
                Text(entry.post.caption)
                Label("\(entry.post.likes) likes", systemImage: "heart")
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
              }
              .padding(.vertical, 6)
            }
          }
          if timeline.hasNextPage {
            Button("Load more") {
              Task { [scope] in await perform(in: scope) { try await timeline.loadNext() } }
            }
            .disabled(timeline.isLoading)
          }
        } else if errors[scope] == nil {
          ProgressView("Loading feed")
            .task(id: scope) { [scope] in
              await perform(in: scope) {
                let timeline = try await stack.resolve(FeedQuery(scope: scope))
                try Task.checkCancellation()
                timelines[scope] = timeline
              }
            }
        } else {
          Button("Retry") { errors[scope] = nil }
        }
      }
      .listStyle(.plain)
      .refreshable {
        if let timeline = timelines[scope] {
          await perform(in: scope) { try await timeline.refresh() }
        }
      }
    }
    .navigationTitle("Ranked feed")
  }

  private func perform(in scope: FeedScope, _ operation: () async throws -> Void) async {
    errors[scope] = nil
    do {
      try await operation()
    } catch {
      if !Task.isCancelled { errors[scope] = error.localizedDescription }
    }
  }
}

private struct FeedPostDetail: View {
  let post: FeedPost

  var body: some View {
    List {
      Section(post.author.name) {
        Text(post.caption)
        Label("\(post.likes) likes", systemImage: "heart")
      }
    }
    .navigationTitle("Post")
  }
}
