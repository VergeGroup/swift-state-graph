import Foundation
import Testing
import os

@testable import StateGraph

/// Covers the ``ThreadLocalValue`` semantics the graph relies on, and the
/// thread-specific-storage component under it.
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
  func readsAndNilRestoresNeverAllocate() async {
    // A dedicated thread starts without a cell for this slot, so the key shows
    // whether an operation allocated one.
    let finished = TestSignal()
    let observed = OSAllocatedUnfairLock<[Bool]>(initialState: [])

    Thread {
      var hasCell: [Bool] = []
      _ = Slots.allocation.value
      hasCell.append(Slots.allocation.key.get() != nil)
      Slots.allocation.replaceValue(nil)
      hasCell.append(Slots.allocation.key.get() != nil)
      Slots.allocation.withValue(nil) {}
      hasCell.append(Slots.allocation.key.get() != nil)
      Slots.allocation.withValue(Probe("installed")) {}
      hasCell.append(Slots.allocation.key.get() != nil)
      let result = hasCell
      observed.withLock { $0 = result }
      finished.signal()
    }.start()

    #expect(await finished.wait(for: .seconds(5)))
    #expect(observed.withLock { $0 } == [false, false, false, true])
  }

  @Test
  func eachThreadAllocatesOneCellPerSlot() async {
    let finished = TestSignal()
    let observed = OSAllocatedUnfairLock<[Bool]>(initialState: [])

    Thread {
      Slots.reuse.withValue(Probe("first")) {}
      let firstCell = Slots.reuse.key.get()
      Slots.reuse.withValue(Probe("second")) {
        Slots.reuse.withValue(Probe("nested")) {}
      }
      Slots.reuse.replaceValue(Probe("third"))
      Slots.reuse.replaceValue(nil)
      let laterCell = Slots.reuse.key.get()
      // Compare outside the lock: raw pointers are not Sendable.
      let result = [firstCell != nil, firstCell == laterCell]
      observed.withLock { $0 = result }
      finished.signal()
    }.start()

    #expect(await finished.wait(for: .seconds(5)))
    #expect(observed.withLock { $0 } == [true, true])
  }

  @Test
  func valuesAreIsolatedPerThread() async {
    // Both sides run on dedicated threads, so the blocking handoff between them
    // never occupies a cooperative-executor worker.
    let finished = TestSignal()
    let observed = OSAllocatedUnfairLock<IsolationObservation?>(initialState: nil)

    Thread {
      let local = Probe("local")

      Slots.isolation.withValue(local) {
        let otherFinished = TestThreadSignal()
        let other = OSAllocatedUnfairLock<(before: String?, after: String?)?>(initialState: nil)

        Thread {
          let before = Slots.isolation.value?.name
          Slots.isolation.replaceValue(Probe("other"))
          let after = Slots.isolation.value?.name
          other.withLock { $0 = (before, after) }
          otherFinished.signal()
        }.start()

        let otherDidFinish = otherFinished.wait(until: Date().addingTimeInterval(5))
        let otherValues = other.withLock { $0 }
        observed.withLock {
          $0 = IsolationObservation(
            otherDidFinish: otherDidFinish,
            otherBefore: otherValues?.before,
            otherAfter: otherValues?.after,
            localAfterOther: Slots.isolation.value?.name
          )
        }
      }

      finished.signal()
    }.start()

    #expect(await finished.wait(for: .seconds(5)))
    #expect(
      observed.withLock { $0 }
        == IsolationObservation(
          otherDidFinish: true,
          otherBefore: nil,
          otherAfter: "other",
          localAfterOther: "local"
        )
    )
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
  static let allocation = ThreadLocalValue<ThreadLocalTests.Probe>()
  static let reuse = ThreadLocalValue<ThreadLocalTests.Probe>()
  static let isolation = ThreadLocalValue<ThreadLocalTests.Probe>()
  static let threadExit = ThreadLocalValue<ThreadLocalTests.Probe>()
  static let reentrant = ThreadLocalValue<ThreadLocalTests.Probe>()
  static let reentrantOther = ThreadLocalValue<ThreadLocalTests.Probe>()
  static let chain = ThreadLocalValue<ThreadLocalTests.Probe>()
}

private struct IsolationObservation: Equatable, Sendable {
  let otherDidFinish: Bool
  let otherBefore: String?
  let otherAfter: String?
  let localAfterOther: String?
}

/// Holds a weak reference that a test can inspect from another thread.
private final class WeakBox<Object: AnyObject & Sendable>: Sendable {

  private struct Reference: Sendable {
    weak var object: Object?
  }

  private let reference = OSAllocatedUnfairLock(initialState: Reference())

  var value: Object? {
    get { reference.withLock { $0.object } }
    set { reference.withLock { $0.object = newValue } }
  }
}
