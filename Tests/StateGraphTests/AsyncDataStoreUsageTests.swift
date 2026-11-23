import CoreGraphics
import StateGraphAsyncDataStore
import Testing

@MainActor
struct AsyncDataStoreUsageTests {

  private struct OffsetFeed: AsyncDataStoreHeader {
    enum Action { case loadNextPage }

    struct Value {
      var items: [Int] = []
      var nextOffset: Int? = 0
    }

    let pageSize: Int
    let fetchPage: @MainActor (_ offset: Int, _ limit: Int) async -> [Int]

    static func receive(
      action: Action,
      header: Self,
      context: AsyncDataStore<Self>.Context,
      on store: isolated AsyncDataStore<Self>
    ) async {
      switch action {
      case .loadNextPage:
        guard let offset = context.value.nextOffset else { return }
        let items = await header.fetchPage(offset, header.pageSize)

        // This endpoint signals the last page with a response shorter than the limit.
        context.update(on: store) { state in
          state.items.append(contentsOf: items)
          state.nextOffset = items.count < header.pageSize ? nil : offset + items.count
        }
      }
    }
  }

  @Test
  func offsetPaginationLoadsOnePagePerAction() async {
    let items = [10, 11, 12, 13, 14]
    var offsets: [Int] = []
    let header = OffsetFeed(pageSize: 2) { offset, limit in
      offsets.append(offset)
      return Array(items.dropFirst(offset).prefix(limit))
    }
    let store = AsyncDataStore(header: header, initial: OffsetFeed.Value())

    await store.sendAndWait(action: .loadNextPage)
    #expect(store.value.items == [10, 11])
    #expect(store.value.nextOffset == 2)

    await store.sendAndWait(action: .loadNextPage)
    #expect(store.value.items == [10, 11, 12, 13])
    #expect(store.value.nextOffset == 4)

    await store.sendAndWait(action: .loadNextPage)
    #expect(store.value.items == items)
    #expect(store.value.nextOffset == nil)

    await store.sendAndWait(action: .loadNextPage)
    #expect(offsets == [0, 2, 4])
  }

  private struct CursorFeed: AsyncDataStoreHeader {
    enum Action { case loadToEnd }

    enum Position: Equatable {
      case start
      case next(String)
      case end
    }

    struct Value {
      var items: [String] = []
      var position: Position = .start
    }

    struct Page {
      let items: [String]
      let nextCursor: String?
    }

    let fetchPage: @MainActor (_ cursor: String?) async -> Page

    static func receive(
      action: Action,
      header: Self,
      context: AsyncDataStore<Self>.Context,
      on store: isolated AsyncDataStore<Self>
    ) async {
      switch action {
      case .loadToEnd:
        while !Task.isCancelled {
          let cursor: String?
          switch context.value.position {
          case .start: cursor = nil
          case .next(let token): cursor = token
          case .end: return
          }

          let page = await header.fetchPage(cursor)

          // Publish each page and its resume position together.
          let didPublish = context.update(on: store) { state in
            state.items.append(contentsOf: page.items)
            state.position = page.nextCursor.map(Position.next) ?? .end
          }
          guard didPublish else { return }
        }
      }
    }
  }

  @Test
  func cursorPaginationFollowsOpaqueTokensUntilTheEndInOneAction() async {
    var cursors: [String?] = []
    let header = CursorFeed { cursor in
      cursors.append(cursor)
      switch cursor {
      case nil:
        return .init(items: ["A", "B"], nextCursor: "v1.eBw")
      case "v1.eBw":
        return .init(items: ["C"], nextCursor: nil)
      default:
        Issue.record("Unexpected cursor: \(String(describing: cursor))")
        return .init(items: [], nextCursor: nil)
      }
    }
    let store = AsyncDataStore(header: header, initial: CursorFeed.Value())

    await store.sendAndWait(action: .loadToEnd)
    #expect(store.value.items == ["A", "B", "C"])
    #expect(store.value.position == .end)

    await store.sendAndWait(action: .loadToEnd)
    #expect(cursors == [nil, "v1.eBw"])
  }

  private struct Timeline: AsyncDataStoreHeader {
    enum Action {
      case loadOlder
      case loadNewer
    }

    struct Value {
      var timestamps: [Int]
      var loadedRange: Range<Int>
    }

    let availableRange: Range<Int>
    let windowSize: Int

    // The endpoint returns timestamps in ascending order from an inclusive lower
    // bound to an exclusive upper bound, expressed in Unix seconds.
    let fetchRange: @MainActor (Range<Int>) async -> [Int]

    static func receive(
      action: Action,
      header: Self,
      context: AsyncDataStore<Self>.Context,
      on store: isolated AsyncDataStore<Self>
    ) async {
      let loaded = context.value.loadedRange
      let range: Range<Int>
      switch action {
      case .loadOlder:
        let from = max(header.availableRange.lowerBound, loaded.lowerBound - header.windowSize)
        range = from..<loaded.lowerBound
      case .loadNewer:
        let to = min(header.availableRange.upperBound, loaded.upperBound + header.windowSize)
        range = loaded.upperBound..<to
      }
      guard !range.isEmpty else { return }

      let timestamps = await header.fetchRange(range)

      context.update(on: store) { state in
        switch action {
        case .loadOlder:
          state.timestamps.insert(contentsOf: timestamps, at: 0)
          state.loadedRange = range.lowerBound..<loaded.upperBound
        case .loadNewer:
          state.timestamps.append(contentsOf: timestamps)
          state.loadedRange = loaded.lowerBound..<range.upperBound
        }
      }
    }
  }

  @Test
  func timelinePaginationExtendsBothBoundsAndAdvancesAcrossEmptyWindows() async {
    let timestamps = [5, 9, 20, 25, 30, 34]
    var requestedRanges: [Range<Int>] = []
    let header = Timeline(availableRange: 5..<35, windowSize: 10) { range in
      requestedRanges.append(range)
      return timestamps.filter { range.contains($0) }
    }
    let initial = Timeline.Value(timestamps: [20, 25], loadedRange: 20..<30)
    let store = AsyncDataStore(header: header, initial: initial)

    await store.sendAndWait(action: .loadOlder)
    #expect(store.value.timestamps == [20, 25])
    #expect(store.value.loadedRange == 10..<30)

    await store.sendAndWait(action: .loadOlder)
    #expect(store.value.timestamps == [5, 9, 20, 25])
    #expect(store.value.loadedRange == 5..<30)

    await store.sendAndWait(action: .loadNewer)
    #expect(store.value.timestamps == timestamps)
    #expect(store.value.loadedRange == 5..<35)

    await store.sendAndWait(action: .loadOlder)
    await store.sendAndWait(action: .loadNewer)
    #expect(requestedRanges == [10..<20, 5..<10, 30..<35])
  }

  private struct ImageLoader: AsyncDataStoreHeader {
    enum Action { case load }
    typealias Value = CGImage?

    let fetchImage: @MainActor () async -> CGImage?

    static func receive(
      action: Action,
      header: Self,
      context: AsyncDataStore<Self>.Context,
      on store: isolated AsyncDataStore<Self>
    ) async {
      switch action {
      case .load:
        guard context.value == nil, let image = await header.fetchImage() else { return }
        context.update(on: store) { $0 = image }
      }
    }
  }

  @Test
  func oneOffLoadingPublishesAnImageAtOneResolution() async throws {
    let bitmap = try #require(CGContext(
      data: nil,
      width: 64,
      height: 48,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let image = try #require(bitmap.makeImage())
    var fetches = 0
    let header = ImageLoader {
      fetches += 1
      return image
    }
    let store = AsyncDataStore(header: header, initial: nil)

    #expect(store.value == nil)
    await store.sendAndWait(action: .load)
    #expect(store.value?.width == 64)
    #expect(store.value?.height == 48)

    await store.sendAndWait(action: .load)
    #expect(fetches == 1)
  }
}
