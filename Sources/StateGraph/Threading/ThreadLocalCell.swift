// The one per-thread object shape and the one thread-exit teardown. All
// `Unmanaged` code for thread-specific storage lives in this file.

/// A per-thread cell owned by a ``ThreadSpecificKey``.
///
/// The key holds the only strong reference from the cell's installation until its
/// thread exits, so the owning thread borrows the cell without reference counting.
/// Subclasses hold an optional payload and override ``drain()``, which lets one
/// type-erased teardown release every kind of cell.
class ThreadLocalCell {

  /// The key this cell is installed under. The teardown reinstalls the cell under
  /// it while the payload is released.
  final let key: ThreadSpecificKey

  init(key: ThreadSpecificKey) {
    self.key = key
  }

  /// Moves the payload out, leaves the cell empty, then releases the payload, so a
  /// deinitializer sees the same state as after an ordinary restore.
  ///
  /// - Returns: `false` when the cell was already empty.
  func drain() -> Bool {
    preconditionFailure("ThreadLocalCell subclasses must override drain()")
  }

  /// Tears down the exiting thread's cell for one key. Only the destructor that
  /// ``ThreadSpecificKey/init()`` registers calls this.
  ///
  /// POSIX has already cleared the slot. A deinitializer that then used the same
  /// slot would allocate a replacement cell and force another destructor pass, so
  /// the cell stays installed while its payload is released, and anything
  /// installed meanwhile is drained in the same pass. A deinitializer that uses a
  /// slot whose destructor already finished re-arms that key, and POSIX destroys it
  /// again in a later pass, up to `PTHREAD_DESTRUCTOR_ITERATIONS`.
  static func threadDidExit(_ pointer: UnsafeMutableRawPointer) {
    // Take back the key's +1 reference.
    let cell = Unmanaged<ThreadLocalCell>.fromOpaque(pointer).takeRetainedValue()
    withExtendedLifetime(cell) {
      cell.key.set(pointer)
      while cell.drain() {}
      // Clear the slot before `cell` is released, so no later access or destructor
      // pass can observe a dangling pointer.
      cell.key.set(nil)
    }
  }

}

extension ThreadSpecificKey {

  /// Borrows the calling thread's cell without retaining it, or returns `nil` when
  /// the thread has none.
  ///
  /// - Precondition: `Cell` is the only cell type ever installed under this key.
  ///   Every slot owns its key privately, so it always installs the same type.
  @inline(__always)
  @available(*, noasync, message: "a task can resume on another thread after any suspension")
  func withInstalledCell<Cell: ThreadLocalCell, R>(
    _: Cell.Type,
    _ body: (Cell) -> R
  ) -> R? {
    guard let pointer = get() else {
      return nil
    }
    // The unchecked conversion is sound by the precondition. The key's +1
    // reference, or the local one `threadDidExit` holds while it runs, outlives
    // `body`, so borrowing skips a retain/release pair on every access.
    //
    // Wrap `body` in a literal: passing the parameter itself converts it to the
    // throwing type `_withUnsafeGuaranteedRef` takes, and the optimizer then stops
    // inlining a caller's closure that calls another closure.
    return Unmanaged<Cell>.fromOpaque(pointer)._withUnsafeGuaranteedRef { body($0) }
  }

  /// Hands a +1 reference to `cell` to the calling thread's slot, which owns it
  /// until the thread exits.
  ///
  /// - Precondition: The calling thread has no cell under this key.
  @available(*, noasync, message: "a task can resume on another thread after any suspension")
  func install(_ cell: ThreadLocalCell) {
    set(Unmanaged.passRetained(cell).toOpaque())
  }

}
