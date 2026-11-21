/// Controls what happens when an action is submitted to a busy store.
public enum AsyncDataStoreTaskMode: Sendable {
  /// Cancel the current action and start the latest replacement after it returns.
  case dropCurrent
  /// Discard the new action while the store has outstanding work.
  case discard
}

/// Handles the actions and state of an `AsyncDataStore`.
public protocol AsyncDataStoreHeader: SendableMetatype {
  associatedtype Action: Sendable
  associatedtype Value: SendableMetatype

  /// Performs one action, optionally publishing state multiple times before returning.
  /// Await any work that belongs to the action here so it finishes before the next action starts.
  @MainActor
  static func receive(action: Action, header: Self, context: AsyncDataStore<Self>.Context) async
}

/// Runs one action at a time, including across suspension points in the handler.
@MainActor
public final class AsyncDataStore<Header: AsyncDataStoreHeader> {

  public enum Phase {
    case idle
    case running(Header.Action)
  }

  /// Gives a handler access to the store's source value and permission to update it
  /// while its action is current and uncancelled.
  @MainActor
  public struct Context {
    private let source: Stored<Header.Value>
    private let canUpdate: () -> Bool

    fileprivate init(source: Stored<Header.Value>, canUpdate: @escaping () -> Bool) {
      self.source = source
      self.canUpdate = canUpdate
    }

    public var value: Header.Value { source.wrappedValue }

    /// Publishes one state change. Returns false if the action has been replaced or finished.
    ///
    /// For reference-backed state, assign an independent value to publish a tracked
    /// change rather than mutating an object already held by the store.
    @discardableResult
    public func update(_ mutation: (inout Header.Value) -> Void) -> Bool {
      guard canUpdate() else { return false }
      var value = source.wrappedValue
      mutation(&value)
      guard canUpdate() else { return false }
      source.wrappedValue = value
      return true
    }
  }

  @MainActor
  private final class Request {
    let action: Header.Action
    let completion: CheckedContinuation<Void, Never>?
    var task: Task<Void, Never>?

    init(action: Header.Action, completion: CheckedContinuation<Void, Never>?) {
      self.action = action
      self.completion = completion
    }
  }

  public let header: Header

  private let source: Stored<Header.Value>
  private nonisolated let derived: Computed<Header.Value>
  private let actionPhase = Stored<Phase>(wrappedValue: .idle)
  private let reduce = Stored<@Sendable (inout Header.Value) -> Void>(wrappedValue: { _ in })

  private var current: Request?
  private var pending: Request?

  public var sourceValue: Header.Value { source.wrappedValue }
  public nonisolated var value: Header.Value { derived.wrappedValue }
  public var phase: Phase { actionPhase.wrappedValue }

  public init(header: Header, initial: Header.Value) {
    self.header = header
    let source = Stored(wrappedValue: initial)
    self.source = source
    self.derived = Computed { [source, reduce] _ in
      var value = source.wrappedValue
      reduce.wrappedValue(&value)
      return value
    }
  }

  /// Sets the synchronous transform used when a reader evaluates `value`.
  ///
  /// The transform can run on the reader's executor and must have no side effects.
  public func setReduce(_ reduce: @escaping @Sendable (inout Header.Value) -> Void) {
    self.reduce.wrappedValue = reduce
  }

  public func send(action: Header.Action, mode: AsyncDataStoreTaskMode = .discard) {
    submit(Request(action: action, completion: nil), mode: mode)
  }

  /// Waits until the action returns, is discarded, or is replaced before it starts.
  /// Use `send` to submit a replacement from inside this store's handler.
  public func sendAndWait(action: Header.Action, mode: AsyncDataStoreTaskMode = .discard) async {
    await withCheckedContinuation { completion in
      submit(Request(action: action, completion: completion), mode: mode)
    }
  }

  private func submit(_ request: Request, mode: AsyncDataStoreTaskMode) {
    guard let current else {
      start(request)
      return
    }

    switch mode {
    case .discard:
      request.completion?.resume()
    case .dropCurrent:
      let replaced = pending
      pending = request
      current.task?.cancel()
      replaced?.completion?.resume()
    }
  }

  private func start(_ request: Request) {
    current = request
    request.task = Task {
      await run(request)
      finish(request)
    }
  }

  private func run(_ request: Request) async {
    guard !Task.isCancelled else { return }
    actionPhase.wrappedValue = .running(request.action)
    guard !Task.isCancelled else { return }

    let context = Context(source: source) { [weak self, weak request] in
      guard let self, let request else { return false }
      return current === request && request.task?.isCancelled == false
    }
    await Header.receive(action: request.action, header: header, context: context)
  }

  private func finish(_ request: Request) {
    request.task = nil
    current = nil

    if let next = pending {
      pending = nil
      start(next)
    } else {
      actionPhase.wrappedValue = .idle
    }

    request.completion?.resume()
  }
}
