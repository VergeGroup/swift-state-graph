#if canImport(Darwin.os.lock)
import Darwin.os.lock
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#else
#error("AllocatedLock requires Darwin, Glibc, Musl, or WinSDK")
#endif

/// A shared, nonrecursive lock that owns the state it protects.
///
/// Copies of this value share one allocation containing both the state and the
/// platform lock. The lock therefore keeps a stable address until the last copy
/// is released. Apple platforms use `os_unfair_lock`, Linux uses `pthread_mutex_t`,
/// and Windows uses an exclusive `SRWLOCK`.
///
/// Use ``withLock(_:)`` to read or mutate state synchronously. The body must not
/// acquire this lock again or suspend. Fairness is not guaranteed.
///
/// The unchecked initializer and access methods support state whose isolation
/// cannot be expressed by `Sendable`. Their caller must prevent unsynchronized
/// access through aliases or values that escape the locked region.
///
/// The allocation and platform split follow Swift Observation's `Locking.swift`:
/// https://github.com/swiftlang/swift/blob/main/stdlib/public/Observation/Sources/Observation/Locking.swift
///
/// Initializers and access methods are inlinable so external clients can
/// specialize short critical sections and eliminate unneeded allocations.
public struct AllocatedLock<State>: @unchecked Sendable {

  #if canImport(Darwin.os.lock)
  /// Apple primitives need no native destruction; the base buffer owns their lifetime.
  /// Avoiding an empty subclass destructor preserves the original allocation cost.
  @usableFromInline
  internal typealias Storage = ManagedBuffer<State, PlatformLock.Primitive>
  #else
  /// One owner for the state and the platform primitive's destruction.
  @usableFromInline
  internal final class Storage: ManagedBuffer<State, PlatformLock.Primitive> {
    @inlinable
    deinit {
      withUnsafeMutablePointerToElements { PlatformLock.deinitialize($0) }
    }
  }
  #endif

  @usableFromInline
  internal let storage: ManagedBuffer<State, PlatformLock.Primitive>

  /// Creates a lock protecting a value that is safe to transfer between threads.
  @inlinable
  public init(initialState: State) where State: Sendable {
    self.init(uncheckedState: initialState)
  }

  /// Creates a lock whose caller guarantees the isolation of its initial state.
  ///
  /// This lock serializes access to the stored value, but cannot protect other
  /// references to that value. Access through those references must follow the
  /// same synchronization or the value's own isolation contract.
  @inlinable
  public init(uncheckedState initialState: State) {
    storage = Storage.create(minimumCapacity: 1) { buffer in
      buffer.withUnsafeMutablePointerToElements { PlatformLock.initialize($0) }
      return initialState
    }
  }

  /// Runs a synchronous operation with exclusive access to the protected state.
  ///
  /// The lock is released when `body` returns or throws. References removed from
  /// state can be returned and released after this call to avoid running their
  /// deinitializers while holding the lock.
  @inlinable
  public func withLock<Result: Sendable>(
    _ body: @Sendable (inout State) throws -> Result
  ) rethrows -> Result {
    try withLockUnchecked(body)
  }

  /// Runs an operation whose captures and result follow a caller-owned isolation contract.
  ///
  /// The state is still accessed under the lock. The caller must ensure that
  /// non-Sendable captures and escaped results are used only in their permitted
  /// isolation domain. The lock is released when `body` returns or throws.
  @inlinable
  public func withLockUnchecked<Result>(
    _ body: (inout State) throws -> Result
  ) rethrows -> Result {
    try storage.withUnsafeMutablePointers { state, lock in
      PlatformLock.lock(lock)
      defer { PlatformLock.unlock(lock) }
      return try body(&state.pointee)
    }
  }

  /// Runs `body` only if the lock can be acquired immediately.
  ///
  /// Returns `nil` without calling `body` when another operation holds the lock.
  /// A successful acquisition is released when `body` returns or throws.
  @inlinable
  public func withLockIfAvailable<Result: Sendable>(
    _ body: @Sendable (inout State) throws -> Result
  ) rethrows -> Result? {
    try withLockIfAvailableUnchecked(body)
  }

  /// Attempts a locked operation whose isolation is guaranteed by the caller.
  ///
  /// This has the same capture and result requirements as ``withLockUnchecked(_:)``.
  /// Returns `nil` without calling `body` if the lock is already held.
  @inlinable
  public func withLockIfAvailableUnchecked<Result>(
    _ body: (inout State) throws -> Result
  ) rethrows -> Result? {
    try storage.withUnsafeMutablePointers { state, lock in
      guard PlatformLock.lockIfAvailable(lock) else { return nil }
      defer { PlatformLock.unlock(lock) }
      return try body(&state.pointee)
    }
  }

  /// The OS-specific operations on a primitive stored inside `Storage`.
  ///
  /// No primitive is copied after initialization. All operations use its address
  /// in the shared allocation, and destruction occurs after the last owner exits.
  @usableFromInline
  internal enum PlatformLock {
    #if canImport(Darwin.os.lock)
    @usableFromInline
    internal typealias Primitive = os_unfair_lock
    #elseif canImport(Glibc) || canImport(Musl)
    @usableFromInline
    internal typealias Primitive = pthread_mutex_t
    #elseif canImport(WinSDK)
    @usableFromInline
    internal typealias Primitive = SRWLOCK
    #endif

    @inlinable
    internal static func initialize(_ pointer: UnsafeMutablePointer<Primitive>) {
      #if canImport(Darwin.os.lock)
      pointer.initialize(to: os_unfair_lock())
      #elseif canImport(Glibc) || canImport(Musl)
      let result = pthread_mutex_init(pointer, nil)
      precondition(result == 0, "pthread_mutex_init failed: \(result)")
      #elseif canImport(WinSDK)
      InitializeSRWLock(pointer)
      #endif
    }

    @inlinable
    internal static func deinitialize(_ pointer: UnsafeMutablePointer<Primitive>) {
      #if canImport(Glibc) || canImport(Musl)
      let result = pthread_mutex_destroy(pointer)
      precondition(result == 0, "pthread_mutex_destroy failed: \(result)")
      #endif
      pointer.deinitialize(count: 1)
    }

    @inlinable
    internal static func lock(_ pointer: UnsafeMutablePointer<Primitive>) {
      #if canImport(Darwin.os.lock)
      os_unfair_lock_lock(pointer)
      #elseif canImport(Glibc) || canImport(Musl)
      let result = pthread_mutex_lock(pointer)
      precondition(result == 0, "pthread_mutex_lock failed: \(result)")
      #elseif canImport(WinSDK)
      AcquireSRWLockExclusive(pointer)
      #endif
    }

    @inlinable
    internal static func unlock(_ pointer: UnsafeMutablePointer<Primitive>) {
      #if canImport(Darwin.os.lock)
      os_unfair_lock_unlock(pointer)
      #elseif canImport(Glibc) || canImport(Musl)
      let result = pthread_mutex_unlock(pointer)
      precondition(result == 0, "pthread_mutex_unlock failed: \(result)")
      #elseif canImport(WinSDK)
      ReleaseSRWLockExclusive(pointer)
      #endif
    }

    @inlinable
    internal static func lockIfAvailable(_ pointer: UnsafeMutablePointer<Primitive>) -> Bool {
      #if canImport(Darwin.os.lock)
      return os_unfair_lock_trylock(pointer)
      #elseif canImport(Glibc) || canImport(Musl)
      let result = pthread_mutex_trylock(pointer)
      if result == EBUSY { return false }
      precondition(result == 0, "pthread_mutex_trylock failed: \(result)")
      return true
      #elseif canImport(WinSDK)
      return TryAcquireSRWLockExclusive(pointer) != 0
      #endif
    }
  }
}

extension AllocatedLock where State == Void {

  /// Creates a shared lock for synchronizing state owned by the caller.
  @inlinable
  public init() {
    self.init(initialState: ())
  }

  /// Runs a synchronous operation while holding the lock.
  @inlinable
  public func withLock<Result: Sendable>(
    _ body: @Sendable () throws -> Result
  ) rethrows -> Result {
    try withLock { _ in try body() }
  }

  /// Runs a synchronous operation whose isolation is guaranteed by the caller.
  @inlinable
  public func withLockUnchecked<Result>(
    _ body: () throws -> Result
  ) rethrows -> Result {
    try withLockUnchecked { _ in try body() }
  }

  /// Runs a synchronous operation only if the lock is immediately available.
  @inlinable
  public func withLockIfAvailable<Result: Sendable>(
    _ body: @Sendable () throws -> Result
  ) rethrows -> Result? {
    try withLockIfAvailable { _ in try body() }
  }

  /// Attempts a synchronous operation whose isolation is guaranteed by the caller.
  @inlinable
  public func withLockIfAvailableUnchecked<Result>(
    _ body: () throws -> Result
  ) rethrows -> Result? {
    try withLockIfAvailableUnchecked { _ in try body() }
  }

  /// Acquires the lock, waiting for its current owner if necessary.
  ///
  /// Pair this with ``unlock()`` on the same thread. Retain at least one handle
  /// until unlocking, and never suspend or acquire this lock recursively. Prefer
  /// ``withLock(_:)`` when the protected operation fits in a closure.
  @available(*, noasync, message: "Use withLock for synchronous locked access")
  @inlinable
  public func lock() {
    storage.withUnsafeMutablePointerToElements { PlatformLock.lock($0) }
  }

  /// Releases a lock acquired by this thread through any shared handle.
  @available(*, noasync, message: "Use withLock for synchronous locked access")
  @inlinable
  public func unlock() {
    storage.withUnsafeMutablePointerToElements { PlatformLock.unlock($0) }
  }

  /// Attempts to acquire the lock immediately, returning whether it succeeded.
  ///
  /// A successful acquisition must be paired with ``unlock()`` on the same
  /// thread, while retaining a handle and without suspending between the calls.
  @available(*, noasync, message: "Use withLockIfAvailable for synchronous locked access")
  @inlinable
  public func lockIfAvailable() -> Bool {
    storage.withUnsafeMutablePointerToElements { PlatformLock.lockIfAvailable($0) }
  }
}
