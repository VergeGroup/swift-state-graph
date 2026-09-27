import Darwin

/// One thread-local slot backed by a dedicated pthread key.
///
/// Every outermost node read installs and restores thread-local markers, so this
/// type sits on the hottest graph paths. Each thread lazily allocates one
/// `ThreadLocalSlotStorage` per slot on its first non-nil install and reuses it
/// for the rest of the thread's lifetime. Reads and replacements therefore cost a
/// `pthread_getspecific` plus a field access, without per-call allocation, string
/// hashing or dynamic casts.
///
/// The storage is reachable only through the owning thread's key, so values never
/// cross threads and the stored field needs no synchronization.
struct ThreadLocalValue<Value>: ~Copyable, Sendable {

  var value: Value? {
    get {
      // A read never allocates storage. A missing entry means nothing was ever
      // installed in this slot on this thread, or this slot's thread-exit
      // destructor has already finished and nothing was installed since.
      withCurrentStorage { $0.value } ?? nil
    }
  }

  private let key: pthread_key_t

  /// Creates the pthread key for this slot.
  ///
  /// Slots are static members, so Swift's lazy global initialization creates each
  /// key exactly once per process. Keys are never deleted.
  init() {
    var key = pthread_key_t()
    let result = pthread_key_create(&key, destroyThreadLocalSlotStorage)
    // Exhausting the process-wide key space is a programming error rather than a
    // recoverable condition.
    precondition(result == 0, "pthread_key_create failed: \(result)")
    self.key = key
  }

  /// Replaces the current value and returns the value that was installed before it.
  ///
  /// The typed-throws transaction entry point uses this primitive instead of a
  /// throwing closure wrapper so its failure type remains unchanged.
  @discardableResult
  func replaceValue(_ value: Value?) -> Value? {
    if let oldValue = withCurrentStorage({ storage in
      // Move the old value out before storing the new one. It is returned and
      // released only after this access ends, so no deinitializer runs while the
      // cell is being mutated.
      let oldValue = storage.value
      storage.value = value
      return oldValue
    }) {
      return oldValue
    }

    // Restoring nil on a thread without storage must not allocate. Besides saving
    // work, this keeps deinitializers that run during pthread key destruction from
    // re-arming an already destroyed key.
    guard let value else {
      return nil
    }

    let storage = ThreadLocalSlotStorage<Value>(key: key, value: value)
    // The key owns this +1 reference until the thread exits; see
    // `destroyThreadLocalSlotStorage`.
    let result = pthread_setspecific(key, Unmanaged.passRetained(storage).toOpaque())
    precondition(result == 0, "pthread_setspecific failed: \(result)")
    return nil
  }

  func withValue<R, Failure: Error>(
    _ value: Value?,
    perform: () throws(Failure) -> R
  ) throws(Failure) -> R {
    let oldValue = replaceValue(value)
    defer {
      replaceValue(oldValue)
    }
    return try perform()
  }

  /// Runs `body` with this thread's storage, or returns `nil` when the thread has
  /// none.
  @inline(__always)
  private func withCurrentStorage<R>(
    _ body: (ThreadLocalSlotStorage<Value>) -> R
  ) -> R? {
    guard let pointer = pthread_getspecific(key) else {
      return nil
    }
    // Only this slot installs entries for its key, and it always installs a
    // `ThreadLocalSlotStorage<Value>`, so the unchecked conversion is sound. The key
    // holds a +1 reference that only this thread's key destructor gives up, and that
    // destructor keeps its own reference while it runs, so the storage outlives
    // `body`. Borrowing it this way skips a retain/release pair on every access.
    return Unmanaged<ThreadLocalSlotStorage<Value>>.fromOpaque(pointer)
      ._withUnsafeGuaranteedRef(body)
  }

}

/// The type-erased part of a per-thread slot cell.
///
/// The pthread destructor receives only a raw pointer, so it releases the
/// installed value through this base class without knowing `Value`.
private class ThreadLocalSlotStorageBase {

  /// The key that owns this storage. The destructor reinstalls the storage under
  /// this key while released values deinitialize.
  fileprivate let key: pthread_key_t

  fileprivate init(key: pthread_key_t) {
    self.key = key
  }

  /// Clears and releases the installed value.
  ///
  /// - Returns: `false` when no value was installed.
  fileprivate func releaseInstalledValue() -> Bool {
    preconditionFailure("ThreadLocalSlotStorage must override releaseInstalledValue()")
  }

}

/// The per-thread cell behind one `ThreadLocalValue` key.
private final class ThreadLocalSlotStorage<Value>: ThreadLocalSlotStorageBase {

  /// The installed value.
  ///
  /// Dynamic exclusivity checks would cost more than the rest of a slot operation,
  /// and no two accesses can overlap. The storage is reachable only from its owning
  /// thread, and every mutation moves the old value out before it is released, so
  /// no deinitializer can re-enter this field while an access is in progress.
  @exclusivity(unchecked) var value: Value?

  fileprivate init(key: pthread_key_t, value: Value?) {
    self.value = value
    super.init(key: key)
  }

  fileprivate override func releaseInstalledValue() -> Bool {
    guard let oldValue = value else {
      return false
    }
    // Empty the slot before the old value is released, so its deinitializer sees
    // the same state as after an ordinary restore.
    value = nil
    withExtendedLifetime(oldValue) {}
    return true
  }

}

/// Releases one thread's storage for one key when that thread exits.
///
/// pthread clears the key before calling its destructor. A deinitializer that then
/// installed a value in the same slot would allocate replacement storage and force
/// another destructor pass, so the storage stays installed while its values are
/// released and any value installed during that release is drained in the same
/// pass. Other slots follow the normal lazy path: a deinitializer that installs a
/// value in a slot whose destructor already ran re-arms that key, and pthread
/// destroys it again in a later pass, up to `PTHREAD_DESTRUCTOR_ITERATIONS`.
private func destroyThreadLocalSlotStorage(_ pointer: UnsafeMutableRawPointer) {
  let storage = Unmanaged<ThreadLocalSlotStorageBase>.fromOpaque(pointer).takeRetainedValue()
  pthread_setspecific(storage.key, pointer)
  while storage.releaseInstalledValue() {}
  // Clear the key before `storage` is released so no later access or destructor
  // pass can observe a dangling pointer.
  pthread_setspecific(storage.key, nil)
}

enum ThreadLocal: Sendable {

  static let registration: ThreadLocalValue<TrackingRegistration> = .init()
  static let subscriptions: ThreadLocalValue<Subscriptions> = .init()
  static let currentNode: ThreadLocalValue<any TypeErasedNode> = .init()
  static let currentCancellable: ThreadLocalValue<GraphTrackingCancellable> = .init()
  static let graphTransaction: ThreadLocalValue<GraphTransactionContext> = .init()
  static let graphTransactionReadScope: ThreadLocalValue<GraphTransactionReadScope> = .init()
  static let graphImmediateWriterScope: ThreadLocalValue<GraphImmediateWriterScope> = .init()
  static let storedInitializationScope: ThreadLocalValue<StoredInitializationScope> = .init()
#if DEBUG
  static let graphMutationProhibition: ThreadLocalValue<GraphMutationProhibition> = .init()
#endif

}
