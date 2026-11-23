import StateGraph

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
  /// Pass caller-specific data in the action. Handlers run in separate tasks from submitters.
  static func receive(
    action: Action,
    header: Self,
    context: AsyncDataStore<Self>.Context,
    on store: isolated AsyncDataStore<Self>
  ) async
}

/// Runs one action at a time, including across suspension points in the handler.
public actor AsyncDataStore<Header: AsyncDataStoreHeader> {

  public enum Phase: Sendable {
    case idle
    case running(Header.Action)
  }

  /// Gives a handler access to the store's source value and permission to update it
  /// while its action is current and uncancelled.
  public struct Context: Sendable {
    private weak var owner: AsyncDataStore?
    private let requestID: UInt64
    private let source: Stored<Header.Value>

    fileprivate init(
      owner: AsyncDataStore,
      requestID: UInt64,
      source: Stored<Header.Value>
    ) {
      self.owner = owner
      self.requestID = requestID
      self.source = source
    }

    public var value: Header.Value { source.wrappedValue }

    /// Publishes one state change on the issuing store's actor.
    /// Returns false if the context belongs to a different store or its action is no longer current and uncancelled.
    ///
    /// For reference-backed state, assign an independent value to publish a tracked
    /// change rather than mutating an object already held by the store.
    @discardableResult
    public func update(
      on store: isolated AsyncDataStore,
      _ mutation: (inout Header.Value) -> Void
    ) -> Bool {
      guard owner === store else { return false }
      return store.update(requestID: requestID, mutation)
    }
  }

  private struct Submission: Sendable {
    let action: Header.Action
    let mode: AsyncDataStoreTaskMode
    let completion: CheckedContinuation<Void, Never>?
  }

  private struct Inbox: Sendable {
    var submissions: [Submission] = []
    var isDraining = false
  }

  private struct RunningRequest {
    let id: UInt64
    let task: Task<Void, Never>
  }

  public let header: Header

  private nonisolated let source: Stored<Header.Value>
  private nonisolated let derived: Computed<Header.Value>
  private nonisolated let actionPhase = Stored<Phase>(wrappedValue: .idle)
  private nonisolated let reduce = Stored<@Sendable (inout Header.Value) -> Void>(wrappedValue: { _ in })

  private nonisolated let inbox = AllocatedLock(initialState: Inbox())
  private var nextRequestID: UInt64 = 0
  private var current: RunningRequest?
  private var pending: Submission?

  public nonisolated var sourceValue: Header.Value { source.wrappedValue }
  public nonisolated var value: Header.Value { derived.wrappedValue }
  public nonisolated var phase: Phase { actionPhase.wrappedValue }

  /// Transfers the header to the store actor.
  public init(header: sending Header, initial: Header.Value) {
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
  public nonisolated func setReduce(_ reduce: @escaping @Sendable (inout Header.Value) -> Void) {
    self.reduce.wrappedValue = reduce
  }

  /// Enqueues the action synchronously. The store applies its mode, including cancellation,
  /// when it processes this submission in enqueue order.
  public nonisolated func send(action: Header.Action, mode: AsyncDataStoreTaskMode = .discard) {
    enqueue(Submission(action: action, mode: mode, completion: nil))
  }

  /// Waits until the action returns, is discarded, or is replaced before it starts.
  /// Use `send` to submit a replacement from inside this store's handler.
  public nonisolated(nonsending) func sendAndWait(
    action: Header.Action,
    mode: AsyncDataStoreTaskMode = .discard
  ) async {
    await withCheckedContinuation { completion in
      enqueue(Submission(action: action, mode: mode, completion: completion))
    }
  }

  private nonisolated func enqueue(_ submission: Submission) {
    let needsDrain = inbox.withLock { inbox in
      inbox.submissions.append(submission)
      guard !inbox.isDraining else { return false }
      inbox.isDraining = true
      return true
    }
    if needsDrain {
      scheduleDrain()
    }
  }

  private nonisolated func scheduleDrain() {
    // A batch can contain submissions from several callers with different task locals.
    Task.detached {
      await self.drain()
    }
  }

  private func drain() {
    let submissions = inbox.withLock { inbox in
      var submissions: [Submission] = []
      swap(&submissions, &inbox.submissions)
      return submissions
    }

    for submission in submissions {
      submit(submission)
    }

    // Leave a scheduling point between batches for the running handler to resume.
    let hasMore = inbox.withLock { inbox in
      guard inbox.submissions.isEmpty else { return true }
      inbox.isDraining = false
      return false
    }
    if hasMore {
      scheduleDrain()
    }
  }

  private func submit(_ request: Submission) {
    guard let current else {
      start(request)
      return
    }

    switch request.mode {
    case .discard:
      request.completion?.resume()
    case .dropCurrent:
      let replaced = pending
      pending = request
      current.task.cancel()
      replaced?.completion?.resume()
    }
  }

  private func start(_ request: Submission) {
    let id = nextRequestID
    nextRequestID += 1
    let task = Task {
      await run(request.action, requestID: id)
      finish(request)
    }
    current = RunningRequest(id: id, task: task)
  }

  private func run(_ action: Header.Action, requestID: UInt64) async {
    guard !Task.isCancelled else { return }
    actionPhase.wrappedValue = .running(action)
    guard !Task.isCancelled else { return }

    let context = Context(owner: self, requestID: requestID, source: source)
    await Header.receive(action: action, header: header, context: context, on: self)
  }

  private func update(requestID: UInt64, _ mutation: (inout Header.Value) -> Void) -> Bool {
    guard canUpdate(requestID: requestID) else { return false }
    var value = source.wrappedValue
    mutation(&value)
    guard canUpdate(requestID: requestID) else { return false }
    source.wrappedValue = value
    return true
  }

  private func canUpdate(requestID: UInt64) -> Bool {
    guard let current else { return false }
    return current.id == requestID && !current.task.isCancelled
  }

  private func finish(_ request: Submission) {
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
