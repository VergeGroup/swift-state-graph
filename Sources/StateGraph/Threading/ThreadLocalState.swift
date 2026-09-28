/// Per-thread state created on a thread's first access and destroyed when the
/// thread exits.
///
/// Use it for per-thread caches that would otherwise need a shared lock. Unlike
/// ``ThreadLocalValue``, nothing installs or restores it around a scope: each thread
/// owns one instance for its whole lifetime and mutates it in place, without locks,
/// copies or reference counting.
///
/// Rules:
/// - Declare instances only as `static let` members of `ThreadLocal`, because each
///   one owns a process-lifetime key.
/// - Neither `body` in ``withCurrent(_:)`` nor the factory may access the same state
///   again, including from a deinitializer they trigger. A re-entrant access traps in
///   every build configuration. Do work that may re-enter, such as building a value
///   to cache, between two accesses instead.
/// - The state never leaves its thread: `body` must not return or store the state, or
///   any reference reachable from it, unless that value is immutable or `Sendable`.
///   Later accesses on the owning thread mutate the state in place, so an escaped
///   mutable reference races with them. The compiler does not check this: the type is
///   `Sendable` for any `State`, and `withCurrent` returns any `R`.
/// - The factory runs outside `body`'s `inout` access, with the access flag set: on a
///   thread's first access, and again when a deinitializer uses the state after the
///   thread's exit teardown destroyed it. Such a replacement is destroyed in the same
///   teardown, or in a later destructor pass when that teardown had already finished,
///   within the pass limit described on ``ThreadSpecificKey``; a replacement still
///   set after the last pass is abandoned and leaks.
struct ThreadLocalState<State>: ~Copyable, Sendable {

  private let key: ThreadSpecificKey
  private let makeInitialState: @Sendable () -> State

  /// Creates the state's key. Keys are never deleted.
  ///
  /// - Parameter makeInitialState: Creates the calling thread's state. Runs once per
  ///   thread, except during thread exit as described on the type.
  init(_ makeInitialState: @escaping @Sendable () -> State) {
    key = ThreadSpecificKey()
    self.makeInitialState = makeInitialState
  }

  /// Gives `body` exclusive, in-place access to the calling thread's state, creating
  /// the state first if the thread has none.
  ///
  /// Allowed in async functions: `body` is synchronous, so the whole access happens on
  /// one thread.
  ///
  /// - Precondition: `body` does not access this state again. A violation traps.
  func withCurrent<R>(_ body: (inout State) -> R) -> R {
    // The outer optional is `nil` when the thread has no cell, the inner one when the
    // cell's state was destroyed during thread exit.
    if let result = key.withInstalledCell(
      ThreadLocalStateCell<State>.self,
      { $0.withStateIfPresent(body) }
    ) ?? nil {
      return result
    }
    return withNewState(body)
  }

  /// The once-per-thread creation, kept out of line so the hot path stays small.
  @inline(never)
  @available(*, noasync, message: "a task can resume on another thread after any suspension")
  private func withNewState<R>(_ body: (inout State) -> R) -> R {
    if key.get() == nil {
      // Installed empty and filled below, so a factory that accesses this state
      // finds the access flag set and traps instead of recursing without bound.
      key.install(ThreadLocalStateCell<State>(key: key))
    }
    // Both unwraps hold: the cell is installed, and `fill` leaves a state in it.
    return key.withInstalledCell(ThreadLocalStateCell<State>.self) { cell in
      cell.fill(makeInitialState)
      return cell.withStateIfPresent(body)!
    }!
  }

}

/// The per-thread cell behind one ``ThreadLocalState``.
private final class ThreadLocalStateCell<State>: ThreadLocalCell {

  /// The thread's state. `nil` only until the first `fill` and after `drain()`.
  ///
  /// ``withStateIfPresent(_:)`` runs caller code while that code holds this field
  /// `inout`, so a re-entrant access must trap rather than alias it. `isAccessed`
  /// enforces that in every build configuration. A dynamically checked field would
  /// trap too, but its access spans the caller's code, so the optimizer keeps it
  /// tracked at run time, which costs several times more per access than this flag.
  /// Only this class touches either field.
  @exclusivity(unchecked) private var state: State?

  /// Set while `body` or the factory runs.
  @exclusivity(unchecked) private var isAccessed = false

  /// Runs `body` with exclusive access to the state, or returns `nil` without running
  /// it when the cell holds no state.
  @inline(__always)
  func withStateIfPresent<R>(_ body: (inout State) -> R) -> R? {
    // Checked before `state` is read, so a re-entrant call traps without touching
    // storage that the outer `body` holds `inout`.
    trapIfAccessed()
    guard state != nil else {
      return nil
    }
    isAccessed = true
    defer {
      isAccessed = false
    }
    // Forcing the optional in place mutates the stored payload without a copy.
    return body(&state!)
  }

  /// Stores the state `makeState` creates in the empty cell.
  func fill(_ makeState: () -> State) {
    trapIfAccessed()
    precondition(state == nil, "ThreadLocalState filled a cell that holds a state")
    isAccessed = true
    let newState = makeState()
    isAccessed = false
    state = newState
  }

  override func drain() -> Bool {
    // The teardown runs only between accesses; this checks that cheaply.
    trapIfAccessed()
    guard let oldState = state else {
      return false
    }
    // Empty the cell before the old state is released, so a deinitializer that uses
    // the state gets a new one instead of the one being destroyed.
    state = nil
    withExtendedLifetime(oldState) {}
    return true
  }

  @inline(__always)
  private func trapIfAccessed() {
    if _slowPath(isAccessed) {
      Self.accessedReentrantly()
    }
  }

  /// Kept out of line so the access stays small enough to inline into its caller,
  /// where `body` is inlined too.
  @inline(never)
  private static func accessedReentrantly() -> Never {
    // Unlike `precondition`, `fatalError` also traps in -Ounchecked builds.
    fatalError("ThreadLocalState accessed re-entrantly")
  }

}
