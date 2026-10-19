// A standalone smoke test for Sources/StateGraph/Threading/, compiled together with
// those files by plain `swiftc` so it runs on platforms where the rest of the
// package does not build yet. SwiftPM ignores this directory.
//
// Every check runs on dedicated threads, because only a real thread exit runs the
// thread-specific-storage destructors.

import Foundation

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

/// A value another thread fills in.
final class Shared<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) {
    storage = value
  }

  var value: Value {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      storage = newValue
    }
  }

  /// Mutates the value in one critical section, so concurrent callers cannot lose
  /// each other's updates the way a get-then-set would.
  func mutate(_ body: (inout Value) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    body(&storage)
  }
}

/// A one-shot signal with a timeout, so a broken destructor fails instead of hanging.
final class Signal: Sendable {
  private let semaphore = DispatchSemaphore(value: 0)

  func signal() {
    semaphore.signal()
  }

  func wait() -> Bool {
    semaphore.wait(timeout: .now() + 5) == .success
  }
}

enum Slots {
  static let isolation = ThreadLocalValue<Probe>()
  static let nested = ThreadLocalValue<Probe>()
  static let allocation = ThreadLocalValue<Probe>()
  static let threadExit = ThreadLocalValue<Probe>()
  static let reentrant = ThreadLocalValue<Probe>()
  static let chain = ThreadLocalValue<Probe>()
}

struct SmokeError: Error {}

let failures = Shared<[String]>([])

func check(_ condition: Bool, _ message: String) {
  if !condition {
    failures.mutate { $0.append(message) }
  }
}

/// Runs `body` on a new thread that exits afterwards, and waits for it to finish.
func onDedicatedThread(_ body: @escaping @Sendable () -> Void) {
  let finished = Signal()
  Thread {
    body()
    finished.signal()
  }.start()
  check(finished.wait(), "dedicated thread did not finish")
}

// Per-thread isolation: a value installed on one thread is invisible to another.
onDedicatedThread {
  Slots.isolation.withValue(Probe("local")) {
    let observed = Shared<[String?]>([])
    onDedicatedThread {
      let before = Slots.isolation.value?.name
      Slots.isolation.replaceValue(Probe("other"))
      observed.value = [before, Slots.isolation.value?.name]
    }
    check(observed.value == [nil, "other"], "isolation: other thread saw \(observed.value)")
    check(Slots.isolation.value?.name == "local", "isolation: local value changed")
  }
}

// Nested scopes restore each previous value, also when the body throws.
onDedicatedThread {
  Slots.nested.withValue(Probe("outer")) {
    Slots.nested.withValue(Probe("inner")) {
      Slots.nested.withValue(nil) {
        check(Slots.nested.value == nil, "nested: nil scope")
      }
      check(Slots.nested.value?.name == "inner", "nested: inner not restored")
    }
    do throws(SmokeError) {
      try Slots.nested.withValue(Probe("throwing")) { () throws(SmokeError) in
        throw SmokeError()
      }
      check(false, "nested: withValue did not rethrow")
    } catch {}
    check(Slots.nested.value?.name == "outer", "nested: outer not restored")
  }
  check(Slots.nested.value == nil, "nested: slot not emptied")
}

// Reads and nil-restores never allocate a cell; the first non-nil install does.
onDedicatedThread {
  _ = Slots.allocation.value
  Slots.allocation.replaceValue(nil)
  Slots.allocation.withValue(nil) {}
  check(Slots.allocation.key.get() == nil, "allocation: read or nil-restore installed a cell")
  Slots.allocation.withValue(Probe("installed")) {}
  check(Slots.allocation.key.get() != nil, "allocation: install did not keep its cell")
}

// A value left installed when its thread exits is released by the destructor.
do {
  let released = Signal()
  onDedicatedThread {
    Slots.threadExit.replaceValue(Probe("leftover") { released.signal() })
  }
  check(released.wait(), "thread exit: leftover value was not released")
}

// A deinitializer that runs during thread exit may use its own slot: it sees the
// slot emptied, and a value it installs there is released too.
do {
  let observedDuringDeinit = Shared<String?>("unset")
  let replacementReleased = Signal()
  onDedicatedThread {
    Slots.reentrant.replaceValue(Probe("first") {
      observedDuringDeinit.value = Slots.reentrant.value?.name
      Slots.reentrant.replaceValue(Probe("replacement") { replacementReleased.signal() })
    })
  }
  check(replacementReleased.wait(), "reentrant: replacement was not released")
  check(observedDuringDeinit.value == nil, "reentrant: deinit saw \(String(describing: observedDuringDeinit.value))")
}

// A chain of deinitializers, each installing the next one in the same slot, is longer
// than the 4 destructor passes of every supported libc. It is fully released only if
// one destructor call drains values installed while it runs.
do {
  let lastReleased = Signal()

  @Sendable func makeLink(_ remaining: Int) -> Probe {
    Probe("link-\(remaining)") {
      if remaining == 0 {
        lastReleased.signal()
      } else {
        Slots.chain.replaceValue(makeLink(remaining - 1))
      }
    }
  }

  onDedicatedThread {
    Slots.chain.replaceValue(makeLink(8))
  }
  check(lastReleased.wait(), "chain: last link was not released")
}

let result = failures.value
if result.isEmpty {
  print("ThreadingSmoke: OK")
} else {
  for failure in result {
    print("ThreadingSmoke FAILED: \(failure)")
  }
  exit(1)
}
