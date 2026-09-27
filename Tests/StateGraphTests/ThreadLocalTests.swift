import Foundation
import Testing
import os

@testable import StateGraph

/// Covers the pthread-backed ``ThreadLocalValue`` semantics the graph relies on.
///
/// Every test uses its own slots so tests running in parallel never share a key.
/// Slots are static members, like the library's own slots, because each one owns a
/// process-wide pthread key that is never deleted.
@Suite("ThreadLocalValue")
struct ThreadLocalTests {

  final class Probe: Sendable {
    let name: String
    let onDeinit: (@Sendable () -> Void)?

    init(_ name: String, onDeinit: (@Sendable () -> Void)? = nil) {
      self.name = name
      self.onDeinit = onDeinit
    }

    deinit {
      onDeinit?()
    }
  }

  struct ProbeError: Error, Equatable {}

  @Test
  func replaceValueReturnsThePreviouslyInstalledValue() {
    let first = Probe("first")
    let second = Probe("second")

    #expect(Slots.replace.value == nil)
    #expect(Slots.replace.replaceValue(first) == nil)
    #expect(Slots.replace.value === first)
    #expect(Slots.replace.replaceValue(second) === first)
    #expect(Slots.replace.value === second)
    #expect(Slots.replace.replaceValue(nil) === second)
    #expect(Slots.replace.value == nil)
    #expect(Slots.replace.replaceValue(nil) == nil)
  }

  @Test
  func nestedWithValueRestoresEachPreviousValue() {
    let outer = Probe("outer")
    let inner = Probe("inner")

    Slots.nested.withValue(outer) {
      #expect(Slots.nested.value === outer)

      Slots.nested.withValue(inner) {
        #expect(Slots.nested.value === inner)

        Slots.nested.withValue(nil) {
          #expect(Slots.nested.value == nil)
        }

        #expect(Slots.nested.value === inner)
      }

      #expect(Slots.nested.value === outer)
    }

    #expect(Slots.nested.value == nil)
  }

  @Test
  func withValueRestoresThePreviousValueWhenTheBodyThrows() {
    let outer = Probe("outer")
    let inner = Probe("inner")

    Slots.throwing.withValue(outer) {
      // The typed failure must propagate unchanged through `withValue`.
      do throws(ProbeError) {
        try Slots.throwing.withValue(inner) { () throws(ProbeError) in
          #expect(Slots.throwing.value === inner)
          throw ProbeError()
        }
        Issue.record("withValue must rethrow the body's error")
      } catch {
        #expect(error == ProbeError())
      }

      #expect(Slots.throwing.value === outer)
    }

    #expect(Slots.throwing.value == nil)
  }

  @Test
  func valuesAreStronglyRetainedWhileInstalled() {
    weak var weakProbe: Probe?

    do {
      let probe = Probe("retained")
      weakProbe = probe
      Slots.retain.replaceValue(probe)
    }

    #expect(weakProbe != nil)
    Slots.retain.replaceValue(nil)
    #expect(weakProbe == nil)
  }

  @Test
  func supportsExistentialAndValueTypes() {
    let node = Stored(wrappedValue: 0)

    Slots.node.withValue(node) {
      #expect(Slots.node.value === node)
    }
    #expect(Slots.node.value == nil)

    #expect(Slots.integer.replaceValue(1) == nil)
    #expect(Slots.integer.replaceValue(2) == 1)
    #expect(Slots.integer.replaceValue(nil) == 2)
  }

  @Test
  func valuesAreIsolatedPerThread() {
    let local = Probe("local")

    Slots.isolation.withValue(local) {
      let other = runOnNewThread {
        let before = Slots.isolation.value?.name
        Slots.isolation.replaceValue(Probe("other"))
        return Observed(before: before, after: Slots.isolation.value?.name)
      }

      #expect(other == Observed(before: nil, after: "other"))
      #expect(Slots.isolation.value === local)
    }
  }

  @Test
  func valueInstalledAtThreadExitIsReleased() async {
    let released = TestSignal()
    let weakProbe = WeakBox<Probe>()

    Thread {
      let probe = Probe("leftover") { released.signal() }
      weakProbe.value = probe
      // Leave the value installed; only thread exit can release it now.
      Slots.threadExit.replaceValue(probe)
    }.start()

    #expect(await released.wait(for: .seconds(5)))
    #expect(weakProbe.value == nil)
  }

  @Test
  func deinitializersMayUseThreadLocalsDuringThreadExit() async {
    let firstReleased = TestSignal()
    let replacementReleased = TestSignal()
    let otherReleased = TestSignal()
    let observedSlotDuringDeinit = OSAllocatedUnfairLock<String?>(initialState: "unset")

    Thread {
      // Give the other slot storage on this thread too, so both keys have a
      // destructor pending when the thread exits.
      Slots.reentrantOther.replaceValue(Probe("other-initial"))
      Slots.reentrantOther.replaceValue(nil)

      let first = Probe("first") {
        observedSlotDuringDeinit.withLock { $0 = Slots.reentrant.value?.name }
        // Leave new values installed in both slots from inside a thread-exit
        // deinitializer. Destructor order across keys is unspecified, so the other
        // slot may already have been torn down.
        Slots.reentrant.replaceValue(Probe("replacement") { replacementReleased.signal() })
        Slots.reentrantOther.replaceValue(Probe("other") { otherReleased.signal() })
        firstReleased.signal()
      }
      Slots.reentrant.replaceValue(first)
    }.start()

    #expect(await firstReleased.wait(for: .seconds(5)))
    #expect(await replacementReleased.wait(for: .seconds(5)))
    #expect(await otherReleased.wait(for: .seconds(5)))
    // The deinitializer observes its own slot as already emptied.
    #expect(observedSlotDuringDeinit.withLock { $0 } == nil)
  }

  @Test
  func deinitializerChainInOneSlotIsDrainedAtThreadExit() async {
    // Each link installs the next one from its deinitializer. The chain is longer
    // than `PTHREAD_DESTRUCTOR_ITERATIONS`, so it is fully released only if one
    // destructor call drains values installed while it runs.
    let chainLength = Int(PTHREAD_DESTRUCTOR_ITERATIONS) + 4
    let lastReleased = TestSignal()

    @Sendable func makeLink(_ remaining: Int) -> Probe {
      Probe("link-\(remaining)") {
        if remaining == 0 {
          lastReleased.signal()
        } else {
          Slots.chain.replaceValue(makeLink(remaining - 1))
        }
      }
    }

    Thread {
      Slots.chain.replaceValue(makeLink(chainLength))
    }.start()

    #expect(await lastReleased.wait(for: .seconds(5)))
  }

}

private enum Slots {
  static let replace = ThreadLocalValue<ThreadLocalTests.Probe>()
  static let nested = ThreadLocalValue<ThreadLocalTests.Probe>()
  static let throwing = ThreadLocalValue<ThreadLocalTests.Probe>()
  static let retain = ThreadLocalValue<ThreadLocalTests.Probe>()
  static let node = ThreadLocalValue<any TypeErasedNode>()
  static let integer = ThreadLocalValue<Int>()
  static let isolation = ThreadLocalValue<ThreadLocalTests.Probe>()
  static let threadExit = ThreadLocalValue<ThreadLocalTests.Probe>()
  static let reentrant = ThreadLocalValue<ThreadLocalTests.Probe>()
  static let reentrantOther = ThreadLocalValue<ThreadLocalTests.Probe>()
  static let chain = ThreadLocalValue<ThreadLocalTests.Probe>()
}

private struct Observed: Equatable, Sendable {
  let before: String?
  let after: String?
}

/// Holds a weak reference that a test can inspect from another thread.
private final class WeakBox<Object: AnyObject>: @unchecked Sendable {
  private let lock = NSLock()
  private weak var _value: Object?

  var value: Object? {
    get { lock.withLock { _value } }
    set { lock.withLock { _value = newValue } }
  }
}

/// Runs `body` on a fresh thread and waits for its result.
///
/// The wait is bounded so a regression fails the test instead of hanging the run.
private func runOnNewThread<Result: Sendable>(
  _ body: @escaping @Sendable () -> Result
) -> Result? {
  let semaphore = DispatchSemaphore(value: 0)
  let result = OSAllocatedUnfairLock<Result?>(initialState: nil)

  Thread {
    let value = body()
    result.withLock { $0 = value }
    semaphore.signal()
  }.start()

  guard semaphore.wait(timeout: .now() + 5) == .success else {
    return nil
  }
  return result.withLock { $0 }
}
