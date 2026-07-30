import os

/// An asynchronous sequence generated from a closure that tracks StateGraph node changes.
///
/// `GraphObservation` provides an `AsyncSequence`-based API for observing one or more
/// StateGraph nodes using Swift Concurrency. The sequence emits the current projection
/// immediately, then emits again after tracked nodes change.
///
/// ## Usage
/// ```swift
/// let firstName = Stored(wrappedValue: "John")
/// let lastName = Stored(wrappedValue: "Doe")
///
/// for await fullName in GraphObservation({
///   "\(firstName.wrappedValue) \(lastName.wrappedValue)"
/// }) {
///   print("Full name: \(fullName)")
/// }
/// ```
///
/// ## Features
/// - Emits the current value immediately on first iteration (startWith behavior)
/// - Dynamically tracks nodes accessed during each emission
/// - Supports task cancellation
/// - Thread-safe using OSAllocatedUnfairLock
/// - Respects actor isolation context
///
/// This implementation is inspired by Apple's Observations pattern.
/// Reference: https://github.com/swiftlang/swift/blob/main/stdlib/public/Observation/Sources/Observation/Observations.swift
public struct GraphObservation<Element: Sendable>: AsyncSequence,
  Sendable
{

  /// The iterator type that produces graph observation values.
  public typealias AsyncIterator = Iterator

  /// A single emission decision from an observation closure.
  ///
  /// Return `.next` to emit a value and continue tracking. Return `.finish` to end
  /// the sequence without emitting another value.
  public enum Iteration: Sendable {
    case next(Element)
    case finish
  }

  enum Emit: Sendable {
    case iteration(@isolated(any) @Sendable () -> Iteration)
    case element(@isolated(any) @Sendable () -> Element)

    var isolation: (any Actor)? {
      switch self {
      case .iteration(let closure):
        return closure.isolation
      case .element(let closure):
        return closure.isolation
      }
    }
  }

  private let emit: Emit

  public init(
    @_inheritActorContext _ emit: @escaping @isolated(any) @Sendable () -> Element
  ) {
    self.emit = .element(emit)
  }

  /// Creates a graph observation that iterates until the closure returns `.finish`.
  ///
  /// Use this when you need programmatic control over when the sequence terminates.
  ///
  /// ## Usage
  /// ```swift
  /// var count = 0
  /// for await value in GraphObservation.untilFinished({
  ///   count += 1
  ///   if count > 5 {
  ///     return .finish
  ///   }
  ///   return .next(someNode.wrappedValue)
  /// }) {
  ///   print(value)
  /// }
  /// ```
  public static func untilFinished(
    @_inheritActorContext _ emit: @escaping @isolated(any) @Sendable () -> Iteration
  ) -> GraphObservation<Element> {
    .init(emit: .iteration(emit))
  }

  private init(emit: Emit) {
    self.emit = emit
  }

  public func makeAsyncIterator() -> Iterator {
    Iterator(emit: emit)
  }

  // State matches Apple's _ManagedCriticalState pattern
  struct State {
    enum Continuation {
      case cancelled
      case active(UnsafeContinuation<Void, Never>)

      func resume() {
        switch self {
        case .cancelled:
          break
        case .active(let continuation):
          continuation.resume()
        }
      }
    }

    var id: Int = 0
    var continuations: [Int: Continuation] = [:]
    var dirty: Bool = false

    // create a generation id for the unique identification of the continuations
    // this allows the shared awaiting of the willSets.
    // Most likely, there wont be more than a handful of active iterations
    // so this only needs to be unique for those active iterations
    // that are in the process of calling next.
    static func generation(_ state: OSAllocatedUnfairLock<State>) -> Int {
      state.withLock { state in
        defer { state.id &+= 1 }
        return state.id
      }
    }

    // the cancellation of awaiting on willSet only ferries in resuming early
    // it is the responsability of the caller to check if the task is actually
    // cancelled after awaiting the willSet to act accordingly.
    static func cancel(_ state: OSAllocatedUnfairLock<State>, id: Int) {
      state.withLock { state in
        guard let continuation = state.continuations.removeValue(forKey: id)
        else {
          // if there was no continuation yet active (e.g. it was cancelled at
          // the start of the invocation, then put a tombstone in to gate that
          // resuming later
          state.continuations[id] = .cancelled
          return nil as Continuation?
        }
        return continuation
      }?.resume()
    }

    // fire off ALL awaiting willChange continuations such that they are no
    // longer pending.
    static func emitWillChange(_ state: OSAllocatedUnfairLock<State>) {
      let continuations = state.withLock { state in
        // if there are no continuations present then we have to set the state as dirty
        // else if this is uncondiitonally set the state might produce duplicate events
        // one for the dirty and one for the continuation.
        if state.continuations.count == 0 {
          state.dirty = true
        }
        defer {
          state.continuations.removeAll()
        }
        return state.continuations.values
      }
      for continuation in continuations {
        continuation.resume()
      }
    }

    // install a willChange continuation into the set of continuations
    // this must take a locally unique id (to the active calls of next)
    static func willChange(
      isolation iterationIsolation: isolated (any Actor)? = #isolation,
      state: OSAllocatedUnfairLock<State>,
      id: Int
    ) async {
      return await withUnsafeContinuation(isolation: iterationIsolation) {
        continuation in
        state.withLock { state in
          defer { state.dirty = false }
          switch state.continuations[id] {
          case .cancelled:
            return continuation as UnsafeContinuation<Void, Never>?
          case .active:
            // the Iterator itself cannot be shared across isolations so any call to next that may share an id is a misbehavior
            // or an internal book-keeping failure
            fatalError("Iterator incorrectly shared across task isolations")
          case .none:
            if state.dirty {
              return continuation
            } else {
              state.continuations[id] = .active(continuation)
              return nil
            }
          }
        }?.resume()
      }
    }
  }

  /// An iterator that emits the current projection, then waits for tracked graph mutations.
  public struct Iterator: AsyncIteratorProtocol {
    // OSAllocatedUnfairLock<State> pattern (Apple's _ManagedCriticalState equivalent)
    private var state: OSAllocatedUnfairLock<State>?
    private let emit: Emit
    private var started = false

    init(emit: Emit) {
      self.emit = emit
      self.state = OSAllocatedUnfairLock(initialState: State())
    }

    fileprivate mutating func terminate(id: Int) -> Element? {
      // this is purely defensive to any leaking out of iteration generation ids
      state?.withLock { state in
        state.continuations.removeValue(forKey: id)
      }?.resume()
      // flag the sequence as terminal by nil'ing out the state
      state = nil
      return nil
    }

    // this is the primary implementation of the tracking
    // it is bound to be called on the specified isolation of the construction
    fileprivate static func trackEmission(
      isolation trackingIsolation: isolated (any Actor)?,
      state: OSAllocatedUnfairLock<State>,
      emit: Emit
    ) -> Iteration {
      let result = withStateGraphTracking {
        switch emit {
        case .element(let element):
          Result(catching: element).map { Iteration.next($0) }
        case .iteration(let iteration):
          Result(catching: iteration)
        }
      } didChange: { [state] in
        // resume all cases where the awaiting continuations are awaiting a willSet
        State.emitWillChange(state)
      }
      return result.get()
    }

    fileprivate mutating func trackEmission(
      isolation iterationIsolation: isolated (any Actor)?,
      state: OSAllocatedUnfairLock<State>,
      id: Int
    ) async -> Element? {
      guard !Task.isCancelled else {
        // the task was cancelled while awaiting a willChange so ensure a proper termination
        return terminate(id: id)
      }
      // start by directly tracking the emission via a withObservation tracking on the isolation specified from the init
      switch await Iterator.trackEmission(
        isolation: emit.isolation,
        state: state,
        emit: emit
      ) {
      case .finish: return terminate(id: id)
      case .next(let element): return element
      }
    }

    public mutating func next() async -> Element? {
      await next(isolation: nil)
    }

    public mutating func next(
      isolation actor: isolated (any Actor)?
    ) async -> Element? {
      
      guard let state else { return nil }

      // Get a unique generation ID for this wait
      let id = State.generation(state)

      // First call: emit immediately (startWith behavior)
      if started == false {
        started = true
        return await trackEmission(isolation: actor, state: state, id: id)
      } else {
        // wait for the willChange (and NOT the value itself)
        // since this is going to be on the isolation of the object (e.g. the isolation specified in the initialization)
        // this will mean our next await for the emission will ensure the suspension return of the willChange context
        // back to the trailing edges of the mutations. In short, this enables the transactionality bounded by the
        // isolation of the mutation.
        await withTaskCancellationHandler(
          operation: {
            await State.willChange(isolation: actor, state: state, id: id)
          },
          onCancel: {
            // ensure to clean out our continuation uon cancellation
            State.cancel(state, id: id)
          },
          isolation: actor
        )
        return await trackEmission(isolation: actor, state: state, id: id)
      }

    }
   
  }
}

@available(*, deprecated, renamed: "GraphObservation")
public typealias GraphTrackings<Element: Sendable> = GraphObservation<Element>
