import StateGraphAsyncDataStore
import SwiftUI

struct AsyncDataStoreDemoView: View {

  @State private var store = AsyncDataStore(header: TrailFeed(), initial: TrailFeed.Value())

  var body: some View {
    let feed = store.value

    List {
      ForEach(feed.titles, id: \.self) { title in
        Text(title)
      }

      Section {
        switch store.phase {
        case .running:
          ProgressView("Loading trails…")
        case .idle:
          if feed.nextOffset != nil {
            Button(feed.titles.isEmpty ? "Load trails" : "Load next page") {
              store.send(action: .loadNextPage)
            }
          } else {
            Text("All trails loaded")
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .navigationTitle("AsyncDataStore")
    .toolbar {
      Button("Reload", systemImage: "arrow.clockwise") {
        store.send(action: .reload, mode: .dropCurrent)
      }
    }
    .task {
      guard store.value.titles.isEmpty else { return }
      await store.sendAndWait(action: .loadNextPage)
    }
  }

  private struct TrailFeed: AsyncDataStoreHeader {

    enum Action {
      case loadNextPage
      case reload
    }

    struct Value {
      var titles: [String] = []
      var nextOffset: Int? = 0
    }

    private let trails = [
      "Harbor Path",
      "Riverside Walk",
      "Fern Gully",
      "Cedar Loop",
      "North Ridge",
      "Meadow Trail",
      "Lakeside Track",
    ]

    static func receive(
      action: Action,
      header: Self,
      context: AsyncDataStore<Self>.Context,
      on store: isolated AsyncDataStore<Self>
    ) async {
      if case .reload = action {
        context.update { $0 = Value() }
      }

      guard let offset = context.value.nextOffset else { return }

      // Simulate a request so the loading and replacement states are visible in the preview.
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled else { return }

      let page = header.trails.dropFirst(offset).prefix(3)
      let end = offset + page.count
      context.update { feed in
        feed.titles.append(contentsOf: page)
        feed.nextOffset = end < header.trails.count ? end : nil
      }
    }
  }
}

#Preview("AsyncDataStore") {
  NavigationStack {
    AsyncDataStoreDemoView()
  }
}
