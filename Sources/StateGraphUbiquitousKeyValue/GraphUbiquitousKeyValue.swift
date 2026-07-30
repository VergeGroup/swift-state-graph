@_exported import StateGraph
import Foundation

/// A reference-identity property wrapper synchronized with one iCloud
/// key-value store key.
///
/// `GraphUbiquitousKeyValue` owns an in-memory `Stored` node together with the
/// iCloud observation and synchronization lifecycle around it. Its projected
/// value is the same `GraphUbiquitousKeyValue` instance, so retaining
/// `$property` preserves synchronization and mutations continue to write
/// through to the iCloud key-value store.
///
/// Use this wrapper for small settings and app state that change infrequently.
/// iCloud propagation is asynchronous, and assigning `wrappedValue` doesn't
/// mean that another device has received the value.
@propertyWrapper
public final class GraphUbiquitousKeyValue<
  Value: UbiquitousKeyValueStorable & SendableMetatype
>: Sendable {
  private struct State: Sendable {
    var lastValue: Value
    var subscription: UbiquitousKeyValueSubscription?
  }

  private let stored: Stored<Value>
  private let key: String
  private let defaultValue: Value
  private let coordinator: UbiquitousKeyValueAccessCoordinator
  private let state: OSAllocatedUnfairLock<State>

  /// Creates a graph-aware value synchronized with the app's iCloud key-value
  /// store.
  ///
  /// The wrapper observes the shared `NSUbiquitousKeyValueStore.default`
  /// instance before the process requests its initial synchronization.
  ///
  /// - Parameters:
  ///   - wrappedValue: The value used when the key is absent or invalid.
  ///   - key: The iCloud key-value store key.
  public convenience init(
    wrappedValue: Value,
    _ key: String
  ) {
    self.init(
      wrappedValue: wrappedValue,
      key,
      coordinator: .shared
    )
  }

  init(
    wrappedValue: Value,
    _ key: String,
    coordinator: UbiquitousKeyValueAccessCoordinator
  ) {
    self.key = key
    self.defaultValue = wrappedValue
    self.coordinator = coordinator

    let initialValue = coordinator.withAccess { client in
      Self.loadValue(
        from: client,
        forKey: key,
        defaultValue: wrappedValue
      )
    }

    self.stored = Stored(wrappedValue: initialValue)
    self.state = OSAllocatedUnfairLock(
      initialState: State(lastValue: initialValue)
    )

    let subscription = coordinator.observeChanges(forKey: key) { [weak self] change in
      guard change.includes(key) else { return }
      self?.refresh()
    }
    state.withLock { $0.subscription = subscription }

    // Close the gap between the initial read and observer installation.
    refresh()
  }

  deinit {
    let subscription = state.withLock { state in
      defer { state.subscription = nil }
      return state.subscription
    }
    subscription?.cancel()
  }

  public var wrappedValue: Value {
    get {
      stored.wrappedValue
    }
    set {
      coordinator.mutateValue(forKey: key) { client in
        if let object = newValue._encodeUbiquitousKeyValue() {
          client.set(object, forKey: key)
        } else {
          client.removeObject(forKey: key)
        }

        // Read through the same decoding path so the graph snapshot reflects
        // the representation the backing store actually accepted.
        enqueue(
          Self.loadValue(
            from: client,
            forKey: key,
            defaultValue: defaultValue
          )
        )
      }
    }
  }

  /// The reference-identity handle for this synchronized value.
  ///
  /// Retaining the projection keeps iCloud key-value store observation active.
  /// Reads participate in graph dependency tracking, and writes follow the
  /// same synchronization path as assigning the wrapped property.
  public var projectedValue: GraphUbiquitousKeyValue<Value> {
    self
  }

  /// Sets a closure to call after the graph value is assigned.
  public func onDidSet(_ handler: @escaping (Value, Value) -> Void) {
    stored.onDidSet(handler)
  }

  private func refresh() {
    coordinator.withAccess { client in
      enqueue(
        Self.loadValue(
          from: client,
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

    coordinator.publish { [weak self] in
      self?.stored.wrappedValue = value
    }
  }

  private static func loadValue(
    from client: any UbiquitousKeyValueStoreClient,
    forKey key: String,
    defaultValue: Value
  ) -> Value {
    guard let object = client.object(forKey: key) else {
      return defaultValue
    }
    return Value._decodeUbiquitousKeyValue(from: object) ?? defaultValue
  }
}
