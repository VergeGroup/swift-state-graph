import Foundation
import Testing
import os

@testable import StateGraph

/// Covers the ``ThreadLocalState`` semantics StateGraph's per-thread caches rely on.
///
/// Every test runs on dedicated `Thread`s, which start without state and whose exit
/// runs the key destructors, and uses its own states so parallel tests never share a
/// key. States are static members, like the library's own, because each one owns a
/// process-wide key that is never deleted.
@Suite("ThreadLocalState")
struct ThreadLocalStateTests {

  typealias Probe = ThreadLocalTests.Probe

  final class Storage {}

  struct Counter {
    var count = 0
    var probe: Probe?
    var storage: Storage?
  }

  @Test
  func stateIsCreatedOncePerThreadAndMutatedInPlace() async {
    let finished = TestSignal()
    let observed = OSAllocatedUnfairLock<[Int]>(initialState: [])

    Thread {
      let first = States.counter.withCurrent { state -> Int in
        state.count += 1
        state.storage = Storage()
        return state.count
      }
      let second = States.counter.withCurrent { state -> Int in
        state.count += 1
        // No copy of the state exists while `body` holds it.
        return isKnownUniquelyReferenced(&state.storage!) ? state.count : -1
      }
      let factoryCallsOnThisThread = States.counterFactoryCalls.withLock { $0 }

      let otherFinished = TestThreadSignal()
      Thread {
        let count = States.counter.withCurrent { state -> Int in
          state.count += 1
          return state.count
        }
        observed.withLock { $0.append(count) }
        otherFinished.signal()
      }.start()
      otherFinished.wait(until: Date().addingTimeInterval(5))

      let factoryCallsAfterOther = States.counterFactoryCalls.withLock { $0 }
      observed.withLock {
        $0 = [first, second, factoryCallsOnThisThread] + $0 + [factoryCallsAfterOther]
      }
      finished.signal()
    }.start()

    #expect(await finished.wait(for: .seconds(5)))
    // Two accesses on the first thread, one factory call; the second thread starts
    // from its own fresh state and calls the factory once more.
    #expect(observed.withLock { $0 } == [1, 2, 1, 1, 2])
  }

  @Test
  func statesAreIsolatedPerThread() async {
    let finished = TestSignal()
    let observed = OSAllocatedUnfairLock<[Int]>(initialState: [])

    Thread {
      States.isolation.withCurrent { $0.count = 10 }

      let otherFinished = TestThreadSignal()
      let other = OSAllocatedUnfairLock<Int?>(initialState: nil)
      Thread {
        let before = States.isolation.withCurrent { state -> Int in
          let before = state.count
          state.count = 20
          return before
        }
        other.withLock { $0 = before }
        otherFinished.signal()
      }.start()
      otherFinished.wait(until: Date().addingTimeInterval(5))

      let otherBefore = other.withLock { $0 } ?? -1
      let local = States.isolation.withCurrent { $0.count }
      observed.withLock { $0 = [otherBefore, local] }
      finished.signal()
    }.start()

    #expect(await finished.wait(for: .seconds(5)))
    #expect(observed.withLock { $0 } == [0, 10])
  }

  @Test
  func stateIsDestroyedAtThreadExit() async {
    let released = TestSignal()

    Thread {
      States.threadExit.withCurrent { $0.probe = Probe("state") { released.signal() } }
    }.start()

    #expect(await released.wait(for: .seconds(5)))
  }

  @Test
  func deinitializerMayUseTheStateDuringThreadExit() async {
    let replacementReleased = TestSignal()
    let observedCount = OSAllocatedUnfairLock<Int?>(initialState: nil)

    Thread {
      States.reentrantExit.withCurrent {
        $0.count = 5
        $0.probe = Probe("first") {
          // Runs while the teardown releases the state. It gets a new state, and the
          // probe it leaves there must be released by the same teardown.
          States.reentrantExit.withCurrent {
            let count = $0.count
            observedCount.withLock { $0 = count }
            $0.probe = Probe("replacement") { replacementReleased.signal() }
          }
        }
      }
    }.start()

    #expect(await replacementReleased.wait(for: .seconds(5)))
    #expect(observedCount.withLock { $0 } == 0)
  }

  @Test
  func deinitializersMayMixValueSlotsAndStatesDuringThreadExit() async {
    let stateReleased = TestSignal()
    let valueReleased = TestSignal()

    Thread {
      // Each teardown installs into the other kind of slot. Destructor order across
      // keys is unspecified, so either key may already have been torn down.
      States.mixedSlot.replaceValue(Probe("value") {
        States.mixed.withCurrent { $0.probe = Probe("from value") { stateReleased.signal() } }
      })
      States.mixed.withCurrent {
        $0.probe = Probe("state") {
          States.mixedSlot.replaceValue(Probe("from state") { valueReleased.signal() })
        }
      }
    }.start()

    #expect(await stateReleased.wait(for: .seconds(5)))
    #expect(await valueReleased.wait(for: .seconds(5)))
  }

  @Test
  func deinitializerMayUseTheStateAfterItsTeardownFinished() async {
    let probeReleased = TestSignal()
    let observedCount = OSAllocatedUnfairLock<Int?>(initialState: nil)

    Thread {
      // Touching the state first creates its key before the value slot's, and Darwin
      // and glibc run destructors in ascending key order, so the state's teardown has
      // finished and cleared the key before the value's deinitializer runs. The
      // deinitializer then installs a new state, which only a later destructor pass
      // can destroy.
      States.lateState.withCurrent { $0.count = 5 }
      States.lateSlot.replaceValue(Probe("value") {
        States.lateState.withCurrent {
          let count = $0.count
          observedCount.withLock { $0 = count }
          $0.probe = Probe("late") { probeReleased.signal() }
        }
      })
    }.start()

    #expect(await probeReleased.wait(for: .seconds(5)))
    #expect(observedCount.withLock { $0 } == 0)
  }

  @Test
  func reentrantAccessTraps() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      States.reentrancy.withCurrent { _ in
        States.reentrancy.withCurrent { $0.count += 1 }
      }
    }

    expectReentrancyDiagnostic(result)
  }

  @Test
  func factoryAccessingItsOwnStateTraps() async {
    let result = await #expect(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      States.reentrantFactory.withCurrent { $0 += 1 }
    }

    expectReentrancyDiagnostic(result)
  }

  /// Checks that the child process stopped at the re-entrancy trap rather than at an
  /// unrelated crash such as a stack overflow.
  private func expectReentrancyDiagnostic(_ result: ExitTest.Result?) {
    let standardError = String(
      decoding: result?.standardErrorContent ?? [],
      as: UTF8.self
    )

    // Match the existing exit-test convention when TSan prevents the child
    // process from installing its interceptors before test code can execute.
    guard !standardError.contains("Interceptors are not working") else { return }

    #expect(standardError.contains("ThreadLocalState accessed re-entrantly"))
  }

}

private enum States {
  static let counterFactoryCalls = OSAllocatedUnfairLock(initialState: 0)
  static let counter = ThreadLocalState {
    counterFactoryCalls.withLock { $0 += 1 }
    return ThreadLocalStateTests.Counter()
  }
  static let isolation = ThreadLocalState { ThreadLocalStateTests.Counter() }
  static let threadExit = ThreadLocalState { ThreadLocalStateTests.Counter() }
  static let reentrantExit = ThreadLocalState { ThreadLocalStateTests.Counter() }
  static let mixed = ThreadLocalState { ThreadLocalStateTests.Counter() }
  static let mixedSlot = ThreadLocalValue<ThreadLocalTests.Probe>()
  static let lateState = ThreadLocalState { ThreadLocalStateTests.Counter() }
  static let lateSlot = ThreadLocalValue<ThreadLocalTests.Probe>()
  static let reentrancy = ThreadLocalState { ThreadLocalStateTests.Counter() }
  static let reentrantFactory: ThreadLocalState<Int> = ThreadLocalState {
    States.reentrantFactory.withCurrent { $0 }
  }
}
