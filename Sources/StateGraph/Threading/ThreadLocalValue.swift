/// A per-thread slot whose value graph operations install and restore around a
/// synchronous scope.
///
/// Every outermost node read installs and restores thread-local markers, so this
/// type sits on the hottest graph paths. Each thread lazily allocates one cell per
/// slot on its first non-nil install and reuses it for the rest of the thread's
/// lifetime. Reads and replacements therefore cost one key lookup plus a field
/// access, without per-call allocation, hashing or dynamic casts.
///
/// The cell is reachable only through the owning thread's key, so values never
/// cross threads and the stored field needs no synchronization. Declare slots only
/// as `static let` members of `ThreadLocal`, because each one owns a
/// process-lifetime key.
struct ThreadLocalValue<Value>: ~Copyable, Sendable {

  /// Internal so tests can check whether a thread has a cell.
  let key: ThreadSpecificKey

  /// Creates the slot's key. Keys are never deleted.
  init() {
    key = ThreadSpecificKey()
  }

  /// The value installed on the calling thread.
  ///
  /// A read never allocates. A missing cell means nothing was ever installed in
  /// this slot on this thread, or this slot's thread-exit teardown has already
  /// finished and nothing was installed since.
  @available(*, noasync, message: "a task can resume on another thread after any suspension")
  var value: Value? {
    key.withInstalledCell(ThreadLocalValueCell<Value>.self) { $0.value } ?? nil
  }

  /// Replaces the calling thread's value and returns the value installed before it.
  ///
  /// Restoring `nil` on a thread without a cell does not allocate. Besides saving
  /// work, this keeps deinitializers that restore during thread exit from re-arming
  /// an already destroyed key.
  ///
  /// The typed-throws transaction entry point pairs this with a `defer` instead of
  /// using ``withValue(_:perform:)``, so its failure type remains unchanged.
  @discardableResult
  @available(*, noasync, message: "pair each replacement with its restore in one synchronous scope, or use withValue")
  func replaceValue(_ newValue: Value?) -> Value? {
    if let oldValue = key.withInstalledCell(ThreadLocalValueCell<Value>.self, { cell in
      // Move the old value out before storing the new one. It is returned and
      // released only after this access ends, so no deinitializer runs while the
      // cell is being mutated.
      let oldValue = cell.value
      cell.value = newValue
      return oldValue
    }) {
      return oldValue
    }
    guard let newValue else {
      return nil
    }
    installCell(newValue)
    return nil
  }

  /// Installs `value` for the duration of `perform`, then restores the previous
  /// value, also when `perform` throws.
  ///
  /// Allowed in async functions: `perform` is synchronous, so the install and the
  /// restore happen on the same thread.
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

  /// The once-per-thread allocation, kept out of line so the hot paths stay small.
  @inline(never)
  @available(*, noasync, message: "a task can resume on another thread after any suspension")
  private func installCell(_ value: Value) {
    key.install(ThreadLocalValueCell<Value>(key: key, value: value))
  }

}

/// The per-thread cell behind one ``ThreadLocalValue``.
private final class ThreadLocalValueCell<Value>: ThreadLocalCell {

  /// The installed value.
  ///
  /// Dynamic exclusivity checks would cost more than the rest of a slot operation,
  /// and no two accesses can overlap: the cell is reachable only from its owning
  /// thread, and every mutation moves the old value out before it is released, so
  /// no deinitializer can re-enter this field while an access is in progress.
  @exclusivity(unchecked) var value: Value?

  init(key: ThreadSpecificKey, value: Value?) {
    self.value = value
    super.init(key: key)
  }

  override func drain() -> Bool {
    guard let oldValue = value else {
      return false
    }
    // Empty the cell before the old value is released, so its deinitializer sees
    // the same state as after an ordinary restore.
    value = nil
    withExtendedLifetime(oldValue) {}
    return true
  }

}
