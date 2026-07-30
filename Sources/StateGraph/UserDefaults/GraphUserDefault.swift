import Foundation

/// A reference-identity property wrapper synchronized with one `UserDefaults` key.
///
/// `GraphUserDefault` owns an in-memory `Stored` node together with the
/// UserDefaults observation and persistence lifecycle around it. Its projected
/// value is the same `GraphUserDefault` instance, so retaining `$property`
/// preserves synchronization and mutations continue to write through to
/// UserDefaults.
@propertyWrapper
public final class GraphUserDefault<
  Value: UserDefaultsStorable & SendableMetatype
>: Sendable {

  /// Sendable ownership wrapper for Foundation's opaque observer token.
  private struct ObserverToken: @unchecked Sendable {
    let value: NSObjectProtocol
  }

  private struct State: Sendable {
    var lastValue: Value
    var observer: ObserverToken?
  }

  private let stored: Stored<Value>

  nonisolated(unsafe)
  private let userDefaults: UserDefaults

  private let key: String
  private let defaultValue: Value
  private let state: OSAllocatedUnfairLock<State>

  /// Creates a value synchronized with a key in the supplied store.
  ///
  /// - Parameters:
  ///   - wrappedValue: The value used when the key is absent or cannot be decoded.
  ///   - key: The UserDefaults key.
  ///   - store: The UserDefaults instance to synchronize with.
  public init(
    wrappedValue: Value,
    _ key: String,
    store: UserDefaults = .standard
  ) {
    self.key = key
    self.defaultValue = wrappedValue
    self.userDefaults = store

    let initialValue = UserDefaultsAccessCoordinator.shared.withAccess {
      Value._getValue(
        from: store,
        forKey: key,
        defaultValue: wrappedValue
      )
    }

    self.stored = Stored(wrappedValue: initialValue)
    self.state = OSAllocatedUnfairLock(
      initialState: State(lastValue: initialValue)
    )

    let observer = ObserverToken(
      value: NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification,
        object: store,
        queue: nil
      ) { [weak self] _ in
        self?.refresh()
      }
    )
    state.withLock { $0.observer = observer }

    // Close the gap between the initial read and observer installation.
    refresh()
  }

  /// Creates a value synchronized with a named UserDefaults suite.
  ///
  /// The initializer fails fast instead of silently writing to the standard
  /// store when the requested suite cannot be created.
  public convenience init(
    wrappedValue: Value,
    _ key: String,
    suiteName: String
  ) {
    guard let store = UserDefaults(suiteName: suiteName) else {
      preconditionFailure("Unable to create UserDefaults suite '\(suiteName)'")
    }
    self.init(wrappedValue: wrappedValue, key, store: store)
  }

  deinit {
    let observer = state.withLock { state in
      defer { state.observer = nil }
      return state.observer
    }

    if let observer {
      NotificationCenter.default.removeObserver(observer.value)
    }
  }

  public var wrappedValue: Value {
    get {
      stored.wrappedValue
    }
    set {
      UserDefaultsAccessCoordinator.shared.withAccess {
        newValue._setValue(to: userDefaults, forKey: key)

        enqueue(
          Value._getValue(
            from: userDefaults,
            forKey: key,
            defaultValue: defaultValue
          )
        )
      }
    }
  }

  /// The reference-identity handle for this synchronized value.
  ///
  /// Retaining the projection keeps UserDefaults observation active. Reads
  /// participate in graph dependency tracking, and writes persist through the
  /// same path as assigning the wrapped property.
  public var projectedValue: GraphUserDefault<Value> {
    self
  }

  /// Sets a closure to call after the graph value is assigned.
  public func onDidSet(_ handler: @escaping (Value, Value) -> Void) {
    stored.onDidSet(handler)
  }

  private func refresh() {
    UserDefaultsAccessCoordinator.shared.withAccess {
      enqueue(
        Value._getValue(
          from: userDefaults,
          forKey: key,
          defaultValue: defaultValue
        )
      )
    }
  }

  private func enqueue(_ value: Value) {
    let shouldPublish = state.withLock { state in
      guard state.lastValue != value else { return false }
      state.lastValue = value
      return true
    }

    guard shouldPublish else { return }

    UserDefaultsAccessCoordinator.shared.publish { [weak self] in
      self?.stored.wrappedValue = value
    }
  }
}
