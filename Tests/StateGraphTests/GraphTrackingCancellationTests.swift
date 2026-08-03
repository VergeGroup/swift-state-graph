import Foundation
import Testing

@testable import StateGraph

@Suite("GraphTrackingCancellation Tests")
struct GraphTrackingCancellationTests {

  private final class Counter: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)

    var current: Int {
      value.withLock { $0 }
    }

    func increment() {
      value.withLock { $0 += 1 }
    }
  }
  
  final class Resource {
    deinit {
      
    }
  }
  
  @Test
  func resourceReleasingGroup() {

    let node = Stored(wrappedValue: 0)

    let pointer = Unmanaged.passRetained(Resource())

    weak var resourceRef: Resource? = pointer.takeUnretainedValue()

    let subscription = withGraphTracking {
      withGraphTrackingGroup { [resource = pointer.takeUnretainedValue()] in
        print(node.wrappedValue)
        print(resource)
      }
    }

    pointer.release()

    #expect(resourceRef != nil)

    subscription.cancel()

    #expect(resourceRef == nil)

  }

  @Test
  func resourceReleasingMap() {

    let node = Stored(wrappedValue: 0)

    let pointer = Unmanaged.passRetained(Resource())

    weak var resourceRef: Resource? = pointer.takeUnretainedValue()

    let subscription = withGraphTracking {
      withGraphTrackingMap(
        { [resource = pointer.takeUnretainedValue()] in
          print(node.wrappedValue)
          print(resource)
          return node.wrappedValue
        }
      ) { value in
        print("Value: \(value)")
      }
    }

    pointer.release()

    #expect(resourceRef != nil)

    subscription.cancel()

    #expect(resourceRef == nil)

  }

  @Test
  func resourceReleasingMapDependency() {

    class ViewModel {
      let node = Stored(wrappedValue: 0)
    }

    let viewModel = ViewModel()

    let pointer = Unmanaged.passRetained(Resource())

    weak var resourceRef: Resource? = pointer.takeUnretainedValue()

    let subscription = withGraphTracking {
      withGraphTrackingMap(
        from: viewModel,
        map: { [resource = pointer.takeUnretainedValue()] vm in
          print(vm.node.wrappedValue)
          print(resource)
          return vm.node.wrappedValue
        }
      ) { value in
        print("Value: \(value)")
      }
    }

    pointer.release()

    #expect(resourceRef != nil)

    subscription.cancel()

    #expect(resourceRef == nil)

  }

  @Test
  func resourceReleasingMapDependencyOnChange() {

    class ViewModel {
      let node = Stored(wrappedValue: 0)
    }

    let viewModel = ViewModel()

    let pointer = Unmanaged.passRetained(Resource())

    weak var resourceRef: Resource? = pointer.takeUnretainedValue()

    let subscription = withGraphTracking {
      withGraphTrackingMap(
        from: viewModel,
        map: { vm in vm.node.wrappedValue }
      ) { [resource = pointer.takeUnretainedValue()] value in
        print("Value: \(value)")
        print(resource)
      }
    }

    pointer.release()

    #expect(resourceRef != nil)

    subscription.cancel()

    #expect(resourceRef == nil)

  }

  @Test
  func viewModelNotRetained() {

    class ViewModel {
      let node = Stored(wrappedValue: 0)
      deinit {
        print("ViewModel deinit")
      }
    }

    let pointer = Unmanaged.passRetained(ViewModel())

    weak var viewModelRef: ViewModel? = pointer.takeUnretainedValue()

    let subscription = withGraphTracking {
      withGraphTrackingMap(
        from: pointer.takeUnretainedValue(),
        map: { vm in vm.node.wrappedValue }
      ) { value in
        print("Value: \(value)")
      }
    }

    // viewModel should be retained only by pointer, not by withGraphTrackingMap
    #expect(viewModelRef != nil)

    pointer.release()

    // After releasing, viewModel should be deallocated
    // because withGraphTrackingMap doesn't retain it
    #expect(viewModelRef == nil)

    subscription.cancel()

  }

  /// Cancels a group's root subscription from that group's rerun handler.
  ///
  /// The admitted invocation continues after `cancel()` returns. The same subscription
  /// must not attempt to reacquire its nonrecursive execution gate during cancellation.
  @Test
  func groupScopeSelfCancellationReturns() async {
    let invalidationTrigger = Stored(wrappedValue: 0)
    let rootSubscription = OSAllocatedUnfairLock<AnyCancellable?>(uncheckedState: nil)

    await withCheckedContinuation { continuation in
      let subscription = withGraphTracking {
        withGraphTrackingGroup(
          {
            guard invalidationTrigger.wrappedValue == 1 else { return }

            rootSubscription.withLockUnchecked { $0 }?.cancel()
            continuation.resume()
          },
          isolation: nil
        )
      }

      rootSubscription.withLockUnchecked { $0 = subscription }
      invalidationTrigger.wrappedValue = 1
    }
  }

  /// Allows an admitted map pipeline to finish after its applier cancels the scope.
  @Test
  func mapPipelineFinishesAfterSelfCancellation() async {
    let invalidationTrigger = Stored(wrappedValue: 0)
    let rootSubscription = OSAllocatedUnfairLock<AnyCancellable?>(uncheckedState: nil)

    await withCheckedContinuation { continuation in
      let subscription = withGraphTracking {
        withGraphTrackingMap(
          {
            let value = invalidationTrigger.wrappedValue
            if value == 1 {
              rootSubscription.withLockUnchecked { $0 }?.cancel()
            }
            return value
          },
          onChange: { value in
            guard value == 1 else { return }
            continuation.resume()
          },
          isolation: nil
        )
      }

      rootSubscription.withLockUnchecked { $0 = subscription }
      invalidationTrigger.wrappedValue = 1
    }
  }

  /// Does not treat `cancel()` as a barrier for an invocation that already started.
  @Test
  func cancellationReturnsBeforeAdmittedHandlerFinishes() async {
    let invalidationTrigger = Stored(wrappedValue: 0)
    let handlerStarted = TestSignal()
    let resumeHandler = DispatchSemaphore(value: 0)
    let handlerFinished = TestSignal()
    let cancellationReturned = TestSignal()
    let rootSubscription = OSAllocatedUnfairLock<AnyCancellable?>(uncheckedState: nil)

    let subscription = withGraphTracking {
      withGraphTrackingGroup(
        {
          guard invalidationTrigger.wrappedValue == 1 else { return }

          handlerStarted.signal()
          resumeHandler.wait()
          handlerFinished.signal()
        },
        isolation: nil
      )
    }
    rootSubscription.withLockUnchecked { $0 = subscription }
    defer {
      resumeHandler.signal()
      subscription.cancel()
    }

    invalidationTrigger.wrappedValue = 1
    #expect(await handlerStarted.wait(for: .seconds(5)))

    DispatchQueue.global().async {
      rootSubscription.withLockUnchecked { $0 }?.cancel()
      cancellationReturned.signal()
    }

    #expect(await cancellationReturned.wait(for: .seconds(5)))
    resumeHandler.signal()
    #expect(await handlerFinished.wait(for: .seconds(5)))
  }

  /// Rejects a nested handler created after its current parent was cancelled.
  @Test
  func nestedHandlerCreatedAfterCancellationDoesNotStart() async {
    let invalidationTrigger = Stored(wrappedValue: 0)
    let nestedGroupInvocationCount = Counter()
    let nestedMapInvocationCount = Counter()
    let rootSubscription = OSAllocatedUnfairLock<AnyCancellable?>(uncheckedState: nil)

    await withCheckedContinuation { continuation in
      let subscription = withGraphTracking {
        withGraphTrackingGroup(
          {
            guard invalidationTrigger.wrappedValue == 1 else { return }

            rootSubscription.withLockUnchecked { $0 }?.cancel()

            withGraphTrackingGroup {
              nestedGroupInvocationCount.increment()
            }

            withGraphTrackingMap(
              {
                nestedMapInvocationCount.increment()
                return 0
              },
              onChange: { _ in },
              isolation: nil
            )

            continuation.resume()
          },
          isolation: nil
        )
      }

      rootSubscription.withLockUnchecked { $0 = subscription }
      invalidationTrigger.wrappedValue = 1
    }

    #expect(nestedGroupInvocationCount.current == 0)
    #expect(nestedMapInvocationCount.current == 0)
  }

  /// Prevents a pass contending for the execution gate from starting after cancellation.
  @Test
  func invocationContendingForExecutionGateDoesNotStartAfterCancellation() async {
    let trackingHandler = GraphTrackingHandler {}
    let firstInvocationStarted = TestSignal()
    let releaseFirstInvocation = DispatchSemaphore(value: 0)
    let firstInvocationFinished = TestSignal()
    let secondInvocationIsReady = TestSignal()
    let secondInvocationReturned = TestSignal()
    let secondInvocationCount = Counter()

    DispatchQueue.global().async {
      trackingHandler.executeIfActive { _ in
        firstInvocationStarted.signal()
        releaseFirstInvocation.wait()
      }
      firstInvocationFinished.signal()
    }
    defer { releaseFirstInvocation.signal() }

    #expect(await firstInvocationStarted.wait(for: .seconds(5)))

    DispatchQueue.global().async {
      secondInvocationIsReady.signal()
      trackingHandler.executeIfActive { _ in
        secondInvocationCount.increment()
      }
      secondInvocationReturned.signal()
    }

    #expect(await secondInvocationIsReady.wait(for: .seconds(5)))
    trackingHandler.cancel()
    releaseFirstInvocation.signal()

    #expect(await firstInvocationFinished.wait(for: .seconds(5)))
    #expect(await secondInvocationReturned.wait(for: .seconds(5)))
    #expect(secondInvocationCount.current == 0)
  }

  @Test
  func cancellationCallbackCanCancelTheSameCancellable() {
    let holder = OSAllocatedUnfairLock<GraphTrackingCancellable?>(initialState: nil)
    let cancellationCount = Counter()
    let cancellable = GraphTrackingCancellable {
      cancellationCount.increment()
      holder.withLock { $0 }?.cancel()
    }
    holder.withLock { $0 = cancellable }

    cancellable.cancel()
    cancellable.cancel()

    #expect(cancellationCount.current == 1)
  }

  @Test
  func childAddedAfterParentCancellationIsCancelledImmediately() {
    let cancellationCount = Counter()
    let parent = GraphTrackingCancellable()
    let child = GraphTrackingCancellable {
      cancellationCount.increment()
    }

    parent.cancel()
    parent.addChild(child)
    child.cancel()

    #expect(cancellationCount.current == 1)
  }

}
