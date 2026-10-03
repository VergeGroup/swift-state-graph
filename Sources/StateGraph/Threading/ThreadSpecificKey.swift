// The only file in `Threading/` that imports a C library or branches on the
// platform. The folder depends on nothing but the standard library and this
// import, and on no other StateGraph type, so CI type-checks and runs it on Linux
// without building the rest of the package.
//
// Porting to another platform means adding a branch to the ladder below, to
// `Primitive` and to each raw operation; the typed layers above stay unchanged.
// Windows (Fls*) and WASI are not implemented yet and stop at `#error`.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#else
#error("Unsupported platform")
#endif

/// A process-lifetime key under which every thread stores one pointer to a
/// retained ``ThreadLocalCell``.
///
/// Rules for every key:
/// - Keys are created only while a `static let` slot initializes, so Swift's lazy
///   global initialization creates each one exactly once. Keys are never deleted,
///   so no destructor can race a deletion.
/// - Each key consumes one entry of a small per-process budget: 128 on musl and
///   Bionic, 512 on Darwin, 1024 on glibc. `ThreadLocal` lists every slot built on
///   this type; the key-path table in `KeyPath.swift` still creates one key of its
///   own.
/// - A thread reads and writes only its own pointer. Pointers never cross threads,
///   so no access needs synchronization.
/// - A non-nil pointer is a +1 retained cell, stored by ``install(_:)``. The key
///   owns that reference until the thread exits, when
///   ``ThreadLocalCell/threadDidExit(_:)`` takes it back. The one exception is
///   that teardown itself: while it drains the cell, it reinstalls the pointer
///   without a +1, and its own local reference keeps the cell alive until it
///   clears the slot again.
/// - At thread exit POSIX clears the slot before it calls the destructor on the
///   exiting thread, and only for a non-nil pointer. The destructor may set this
///   key and others again; POSIX then runs another pass, at most
///   `PTHREAD_DESTRUCTOR_ITERATIONS` passes in total (4 on Darwin, glibc, musl and
///   Bionic), and abandons whatever is still set after that.
/// - Returning from `main` calls `exit()`, which runs no destructors, so the main
///   thread's cells are never torn down. The process is ending, so this is
///   harmless.
///
/// Windows and WASI are not implemented yet; building for them stops at
/// `#error("Unsupported platform")`.
struct ThreadSpecificKey: Sendable {

  #if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android)
  /// `UInt` on Darwin, `UInt32` on glibc and musl, `Int32` on Bionic. Kept opaque
  /// and only ever produced by `pthread_key_create`.
  typealias Primitive = pthread_key_t
  #else
  #error("Unsupported platform")
  #endif

  private let primitive: Primitive

  /// Creates a key whose thread-exit destructor is
  /// ``ThreadLocalCell/threadDidExit(_:)``.
  init() {
    primitive = Self.create()
  }

  /// The calling thread's pointer, or `nil` when it has none.
  @inline(__always)
  @available(*, noasync, message: "a task can resume on another thread after any suspension")
  func get() -> UnsafeMutableRawPointer? {
    Self.get(primitive)
  }

  /// Replaces the calling thread's pointer.
  ///
  /// Retains and releases nothing: ownership moves with the pointer as described
  /// on the type.
  @inline(__always)
  @available(*, noasync, message: "a task can resume on another thread after any suspension")
  func set(_ pointer: UnsafeMutableRawPointer?) {
    Self.set(primitive, pointer)
  }

  // MARK: Raw platform operations

  private static func create() -> Primitive {
    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android)
    var primitive = Primitive()
    // Darwin imports the destructor's parameter as non-optional; glibc, musl and
    // Bionic import it as optional. The closure's parameter type is inferred from
    // whichever import is present, and rebinding it as optional type-checks
    // against both. A named function could match only one of them.
    let result = pthread_key_create(&primitive) { pointer in
      let pointer: UnsafeMutableRawPointer? = pointer
      guard let pointer else { return }
      ThreadLocalCell.threadDidExit(pointer)
    }
    // Exhausting the process-wide key budget is a programming error rather than a
    // recoverable condition.
    precondition(result == 0, "pthread_key_create failed: \(result)")
    return primitive
    #else
    #error("Unsupported platform")
    #endif
  }

  @inline(__always)
  private static func get(_ primitive: Primitive) -> UnsafeMutableRawPointer? {
    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android)
    // Imported as `UnsafeMutableRawPointer?` on Darwin and Bionic and as
    // `UnsafeMutableRawPointer!` on glibc and musl; the declared return type
    // normalizes both.
    pthread_getspecific(primitive)
    #else
    #error("Unsupported platform")
    #endif
  }

  @inline(__always)
  private static func set(_ primitive: Primitive, _ pointer: UnsafeMutableRawPointer?) {
    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android)
    let result = pthread_setspecific(primitive, pointer)
    // Fails only for an invalid key or when the implementation cannot allocate
    // the thread's slot table; neither is recoverable.
    precondition(result == 0, "pthread_setspecific failed: \(result)")
    #else
    #error("Unsupported platform")
    #endif
  }

}
