import Foundation

/// The reason attached to an external iCloud key-value store notification.
enum UbiquitousKeyValueStoreChangeReason: Equatable, Sendable {
  case local
  case server
  case initialSync
  case quotaViolation
  case account
  case unknown(Int?)
}

/// A normalized external change delivered by an iCloud key-value store client.
struct UbiquitousKeyValueStoreChange: Equatable, Sendable {
  let reason: UbiquitousKeyValueStoreChangeReason
  let changedKeys: Set<String>?

  func includes(_ key: String) -> Bool {
    switch reason {
    case .local, .server, .initialSync:
      changedKeys?.contains(key) ?? true
    case .account:
      // An account replacement can remove keys without listing each old key.
      true
    case .quotaViolation:
      false
    case .unknown:
      false
    }
  }
}

/// The synchronous store operations needed by `GraphUbiquitousKeyValue`.
///
/// The production client wraps `NSUbiquitousKeyValueStore.default`. Keeping
/// this boundary internal to the extension module lets tests provide a
/// deterministic store without exposing a second public storage abstraction.
protocol UbiquitousKeyValueStoreClient: AnyObject {
  func object(forKey key: String) -> Any?
  func set(_ object: Any, forKey key: String)
  func removeObject(forKey key: String)
  func synchronize() -> Bool
  func observe(
    _ receiveChange: @escaping @Sendable (UbiquitousKeyValueStoreChange) -> Void
  ) -> UbiquitousKeyValueStoreObservation
}

/// Owns one idempotent observation-cancellation action.
final class UbiquitousKeyValueStoreObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancellation: (@Sendable () -> Void)?

  init(cancellation: @escaping @Sendable () -> Void) {
    self.cancellation = cancellation
  }

  deinit {
    cancel()
  }

  func cancel() {
    lock.lock()
    let cancellation = self.cancellation
    self.cancellation = nil
    lock.unlock()

    cancellation?()
  }
}

/// Adapts the app-wide Foundation iCloud key-value store to the internal client.
final class FoundationUbiquitousKeyValueStoreClient: UbiquitousKeyValueStoreClient {
  private struct ObserverToken: @unchecked Sendable {
    let value: NSObjectProtocol
  }

  private let store: NSUbiquitousKeyValueStore

  init(store: NSUbiquitousKeyValueStore) {
    self.store = store
  }

  func object(forKey key: String) -> Any? {
    store.object(forKey: key)
  }

  func set(_ object: Any, forKey key: String) {
    store.set(object, forKey: key)
  }

  func removeObject(forKey key: String) {
    store.removeObject(forKey: key)
  }

  func synchronize() -> Bool {
    store.synchronize()
  }

  func observe(
    _ receiveChange: @escaping @Sendable (UbiquitousKeyValueStoreChange) -> Void
  ) -> UbiquitousKeyValueStoreObservation {
    let token = NotificationCenter.default.addObserver(
      forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
      object: store,
      queue: nil
    ) { notification in
      receiveChange(Self.change(from: notification.userInfo))
    }

    let observerToken = ObserverToken(value: token)
    return UbiquitousKeyValueStoreObservation {
      NotificationCenter.default.removeObserver(observerToken.value)
    }
  }

  /// Normalizes Foundation notification metadata into the coordinator's
  /// deterministic change model.
  static func change(
    from userInfo: [AnyHashable: Any]?
  ) -> UbiquitousKeyValueStoreChange {
    let rawReason = (userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey]
      as? NSNumber)?.intValue

    let reason: UbiquitousKeyValueStoreChangeReason
    switch rawReason {
    case NSUbiquitousKeyValueStoreServerChange:
      reason = .server
    case NSUbiquitousKeyValueStoreInitialSyncChange:
      reason = .initialSync
    case NSUbiquitousKeyValueStoreQuotaViolationChange:
      reason = .quotaViolation
    case NSUbiquitousKeyValueStoreAccountChange:
      reason = .account
    default:
      reason = .unknown(rawReason)
    }

    let changedKeys = (
      userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
    ).map(Set.init)

    return UbiquitousKeyValueStoreChange(
      reason: reason,
      changedKeys: changedKeys
    )
  }
}
