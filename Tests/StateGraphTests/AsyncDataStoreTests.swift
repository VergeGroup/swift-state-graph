import Foundation
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

    let handle: @Sendable (Action, Store.Context, isolated Store) async -> Void

    static func receive(
      action: Action,
      header: Self,
      context: Store.Context,
      on store: isolated Store
    ) async {
      await header.handle(action, context, store)
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

    let actions = AllocatedLock(initialState: [Header.Action]())
    let firstFinished = AllocatedLock(initialState: false)
    let store = Store(
      header: Header { action, context, store in
        actions.withLock { $0.append(action) }
        switch action {
        case .first:
          defer { firstFinished.withLock { $0 = true } }
          #expect(context.update(on: store) { $0.append(1) })
          let released = await withTaskCancellationHandler {
            started.signal()
            return await finishFirst.wait(for: .seconds(10))
          } onCancel: {
            cancelled.signal()
          }
          #expect(released)
          #expect(Task.isCancelled)
          #expect(!context.update(on: store) { _ in
            Issue.record("The cancelled action must not run the mutation closure")
          })
        case .latest:
          #expect(firstFinished.withLock { $0 })
          #expect(context.value == [1])
          #expect(context.update(on: store) { $0.append(3) })
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

    #expect(actions.withLock { $0 } == [.first])
    guard case .running(.first) = store.phase else {
      Issue.record("The cancelled action should stay active until its handler returns")
      return
    }

    finishFirst.signal()
    try await #require(latestWaiterReturned.wait(for: .seconds(5)))
    #expect(actions.withLock { $0 } == [.first, .latest])
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

    let savedContext = AllocatedLock<Store.Context?>(initialState: nil)
    let store = Store(
      header: Header { _, context, store in
        savedContext.withLock { $0 = context }
        #expect(context.update(on: store) { $0.append(1) })
        publishedFirstPage.signal()
        #expect(await fetchNextPage.wait(for: .seconds(10)))
        #expect(context.update(on: store) { $0.append(2) })
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

    let context = try #require(savedContext.withLock { $0 })
    let didPublish = await context.update(on: store) { @Sendable value in
      value.removeAll()
    }
    #expect(!didPublish)
    #expect(store.sourceValue == [1, 2])
  }

  @Test
  func synchronousSendsAndSendAndWaitShareFIFOAdmission() async throws {
    let started = TestSignal()
    let wasCancelled = AllocatedLock(initialState: false)
    let finishFirst = TestSignal()
    let published = TestSignal()
    let entities = Stored(wrappedValue: [Int]())
    defer { finishFirst.signal() }

    let store = Store(
      header: Header { action, context, store in
        switch action {
        case .first:
          await withTaskCancellationHandler {
            started.signal()
            #expect(await finishFirst.wait(for: .seconds(10)))
          } onCancel: {
            wasCancelled.withLock { $0 = true }
          }
        case .latest:
          withGraphTransaction {
            let didPublish = context.update(on: store) { list in
              #expect(!Thread.isMainThread)
              entities.wrappedValue.append(3)
              list = [3]
            }
            #expect(didPublish)
            #expect(store.sourceValue == [3])
            #expect(entities.wrappedValue == [3])
          }
          published.signal()
        case .superseded, .discarded:
          Issue.record("Unexpected action: \(action)")
        }
      },
      initial: [Int]()
    )

    store.send(action: .first)
    try await #require(started.wait(for: .seconds(5)))

    store.send(action: .superseded, mode: .dropCurrent)
    store.send(action: .latest, mode: .dropCurrent)
    await store.sendAndWait(action: .discarded)
    #expect(wasCancelled.withLock { $0 })
    #expect(store.sourceValue.isEmpty)
    #expect(entities.wrappedValue.isEmpty)

    finishFirst.signal()
    try await #require(published.wait(for: .seconds(5)))
    #expect(store.sourceValue == [3])
    #expect(entities.wrappedValue == [3])
  }
}
