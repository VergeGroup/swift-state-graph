import StateGraph
import StateGraphAsyncDataStore
import Testing

@MainActor
struct AsyncDataStoreTests {

  private typealias Store = AsyncDataStore<Header>

  private struct Header: AsyncDataStoreHeader {
    typealias Value = [Int]

    enum Action: Equatable {
      case first
      case superseded
      case latest
      case discarded
    }

    let handle: @MainActor (Action, Store.Context) async -> Void

    static func receive(action: Action, header: Self, context: Store.Context) async {
      await header.handle(action, context)
    }
  }

  @Test
  func onlyLatestReplacementRunsAfterCancelledActionReturns() async throws {
    let started = TestSignal()
    let cancelled = TestSignal()
    let finishFirst = TestSignal()
    let supersededWaiterReturned = TestSignal()
    let latestWaiterReturned = TestSignal()
    let discardedWaiterReturned = TestSignal()
    defer { finishFirst.signal() }

    var actions: [Header.Action] = []
    var firstFinished = false
    let store = Store(
      header: Header { action, context in
        actions.append(action)
        switch action {
        case .first:
          defer { firstFinished = true }
          #expect(context.update { $0.append(1) })
          let released = await withTaskCancellationHandler {
            started.signal()
            return await finishFirst.wait(for: .seconds(10))
          } onCancel: {
            cancelled.signal()
          }
          #expect(released)
          #expect(Task.isCancelled)
          #expect(!context.update { $0.append(2) })
        case .latest:
          #expect(firstFinished)
          #expect(context.value == [1])
          #expect(context.update { $0.append(3) })
        case .superseded, .discarded:
          Issue.record("Unexpected action: \(action)")
        }
      },
      initial: [Int]()
    )

    store.send(action: .first)
    try await #require(started.wait(for: .seconds(5)))

    Task {
      await store.sendAndWait(action: .superseded, mode: .dropCurrent)
      supersededWaiterReturned.signal()
    }
    try await #require(cancelled.wait(for: .seconds(5)))

    Task {
      await store.sendAndWait(action: .latest, mode: .dropCurrent)
      latestWaiterReturned.signal()
    }
    try await #require(supersededWaiterReturned.wait(for: .seconds(5)))
    Task {
      await store.sendAndWait(action: .discarded)
      discardedWaiterReturned.signal()
    }
    try await #require(discardedWaiterReturned.wait(for: .seconds(5)))

    #expect(actions == [.first])
    guard case .running(.first) = store.phase else {
      Issue.record("The cancelled action should stay active until its handler returns")
      return
    }

    finishFirst.signal()
    try await #require(latestWaiterReturned.wait(for: .seconds(5)))
    #expect(actions == [.first, .latest])
    #expect(store.sourceValue == [1, 3])
    guard case .idle = store.phase else {
      Issue.record("The store should be idle after the last action returns")
      return
    }
  }

  @Test
  func anActionCanPublishMultipleUpdatesToTheDerivedValue() async throws {
    let publishedFirstPage = TestSignal()
    let fetchNextPage = TestSignal()
    let actionReturned = TestSignal()
    defer { fetchNextPage.signal() }

    var savedContext: Store.Context?
    let store = Store(
      header: Header { _, context in
        savedContext = context
        #expect(context.update { $0.append(1) })
        publishedFirstPage.signal()
        #expect(await fetchNextPage.wait(for: .seconds(10)))
        #expect(context.update { $0.append(2) })
      },
      initial: [Int]()
    )
    store.setReduce { $0 = $0.map { $0 * 10 } }
    let itemCount = Computed { _ in store.value.count }
    #expect(store.value.isEmpty)
    #expect(itemCount.wrappedValue == 0)

    Task {
      await store.sendAndWait(action: .first)
      actionReturned.signal()
    }
    try await #require(publishedFirstPage.wait(for: .seconds(5)))
    #expect(store.sourceValue == [1])
    #expect(store.value == [10])
    #expect(itemCount.wrappedValue == 1)

    fetchNextPage.signal()
    try await #require(actionReturned.wait(for: .seconds(5)))
    #expect(store.sourceValue == [1, 2])
    #expect(store.value == [10, 20])
    #expect(itemCount.wrappedValue == 2)

    let context = try #require(savedContext)
    #expect(!context.update { $0.removeAll() })
    #expect(store.sourceValue == [1, 2])
  }
}
