import Foundation
import Testing

@testable import StateGraph

@Suite("GraphTrackingHandler Tests")
struct GraphTrackingHandlerTests {

  private final class Counter: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)

    var current: Int {
      value.withLock { $0 }
    }

    @discardableResult
    func increment() -> Int {
      value.withLock {
        $0 += 1
        return $0
      }
    }
  }

  private final class HandlerHolder: @unchecked Sendable {
    private let handler = OSAllocatedUnfairLock<GraphTrackingHandler?>(initialState: nil)

    func store(_ handler: GraphTrackingHandler) {
      self.handler.withLock { $0 = handler }
    }

    func invoke() {
      handler.withLock { $0 }?.invoke()
    }

    func cancel() {
      handler.withLock { $0 }?.cancel()
    }
  }

  private final class InvocationProbe: @unchecked Sendable {
    private struct State {
      var activeCount = 0
      var maximumActiveCount = 0
      var invocationCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let firstInvocationStarted = DispatchSemaphore(value: 0)
    let resumeFirstInvocation = DispatchSemaphore(value: 0)

    var result: (invocationCount: Int, maximumActiveCount: Int) {
      state.withLock { ($0.invocationCount, $0.maximumActiveCount) }
    }

    func invoke() {
      let invocationCount = state.withLock { state in
        state.activeCount += 1
        state.maximumActiveCount = max(state.maximumActiveCount, state.activeCount)
        state.invocationCount += 1
        return state.invocationCount
      }

      if invocationCount == 1 {
        firstInvocationStarted.signal()
        resumeFirstInvocation.wait()
      }

      state.withLock { $0.activeCount -= 1 }
    }
  }

  @Test
  func trackingHandlerCanCancelItself() {
    let holder = HandlerHolder()
    let invocationCount = Counter()
    let handler = GraphTrackingHandler {
      invocationCount.increment()
      holder.cancel()
    }
    holder.store(handler)

    handler.invoke()
    handler.invoke()

    #expect(invocationCount.current == 1)
  }

  @Test
  func reentrantInvocationsCoalesceIntoOneRerun() {
    let holder = HandlerHolder()
    let invocationCount = Counter()
    let handler = GraphTrackingHandler {
      if invocationCount.increment() == 1 {
        holder.invoke()
        holder.invoke()
      }
    }
    holder.store(handler)

    handler.invoke()

    #expect(invocationCount.current == 2)
  }

  @Test
  func concurrentInvocationsAreSerializedAndCoalesced() {
    let probe = InvocationProbe()
    let handler = GraphTrackingHandler {
      probe.invoke()
    }
    let firstInvocationFinished = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
      handler.invoke()
      firstInvocationFinished.signal()
    }

    #expect(probe.firstInvocationStarted.wait(timeout: .now() + 1) == .success)

    let pendingInvocations = DispatchGroup()
    for _ in 0..<10 {
      pendingInvocations.enter()
      DispatchQueue.global().async {
        handler.invoke()
        pendingInvocations.leave()
      }
    }

    #expect(pendingInvocations.wait(timeout: .now() + 1) == .success)
    probe.resumeFirstInvocation.signal()
    #expect(firstInvocationFinished.wait(timeout: .now() + 1) == .success)

    let result = probe.result
    #expect(result.invocationCount == 2)
    #expect(result.maximumActiveCount == 1)
  }
}
