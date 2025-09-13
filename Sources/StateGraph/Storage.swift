// MARK: - Storage Protocol

public protocol Storage<Value>: Sendable {
  
  associatedtype Value
      
  mutating func loaded(context: StorageContext)
  
  func unloaded() 
  
  var value: Value { get set }
  
}

public struct StorageContext: Sendable {
  
  private let onStorageUpdated: @Sendable () -> Void
    
  init(onStorageUpdated: @Sendable @escaping () -> Void) {
    self.onStorageUpdated = onStorageUpdated
  }
  
  public func notifyStorageUpdated() {
    onStorageUpdated()
  }
  
}

// MARK: - Concrete Storage Implementations

public struct InMemoryStorage<Value>: Storage {
  
  nonisolated(unsafe)
  public var value: Value
  
  public init(initialValue: consuming Value) {
    self.value = initialValue
  }
    
  public func loaded(context: StorageContext) {
    
  }
  
  public func unloaded() {
    
  }
    
}

// MARK: - Storage Markers

public struct MemoryMarker {
  public static var memory: MemoryMarker {
    MemoryMarker()
  }
}

// MARK: - Convenience Initializers

extension _Stored {
  /// Convenience initializer for InMemory storage
  public convenience init<Value>(
    storage marker: MemoryMarker,
    value: Value,
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: StaticString? = nil
  ) where S == InMemoryStorage<Value> {
    self.init(
      file,
      line,
      column,
      name: name,
      storage: InMemoryStorage(initialValue: value)
    )
  }

}


#if canImport(Foundation)
import Foundation

public final class UserDefaultsStorage<Value: UserDefaultsStorable>: Storage, Sendable {
  
  nonisolated(unsafe)
  private let userDefaults: UserDefaults
  private let key: String
  private let defaultValue: Value
  
  nonisolated(unsafe)
  private var subscription: NSObjectProtocol?
  
  nonisolated(unsafe)
  private var cachedValue: Value?
  
  public var value: Value {
    get {
      if let cachedValue {
        return cachedValue
      }
      let loadedValue = Value._getValue(
        from: userDefaults,
        forKey: key,
        defaultValue: defaultValue
      )
      cachedValue = loadedValue
      return loadedValue
    }
    set {
      cachedValue = newValue
      newValue._setValue(to: userDefaults, forKey: key)
    }
  }
  
  nonisolated(unsafe)
  private var previousValue: Value?
  
  public init(
    userDefaults: UserDefaults,
    key: String,
    defaultValue: Value
  ) {
    self.userDefaults = userDefaults
    self.key = key
    self.defaultValue = defaultValue
  }
     
  public func loaded(context: StorageContext) {
    
    previousValue = value
    
    subscription = NotificationCenter.default
      .addObserver(
        forName: UserDefaults.didChangeNotification,
        object: userDefaults,
        queue: nil,
        using: { [weak self] _ in                      
          guard let self else { return }
          
          // Invalidate cache and reload value
          self.cachedValue = nil
          let value = self.value
          guard self.previousValue != value else {
            return
          }
          
          self.previousValue = value
          
          context.notifyStorageUpdated()
        }
      )
  }  
  
  public func unloaded() {
    guard let subscription else { return }
    NotificationCenter.default.removeObserver(subscription)
  }
}

public struct UserDefaultsMarker {
  let key: String
  let suite: String?
  let name: String?
  
  public static func userDefaults(
    key: String,
    suite: String? = nil,
    name: String? = nil
  ) -> UserDefaultsMarker {
    UserDefaultsMarker(key: key, suite: suite, name: name)
  }
}

extension _Stored {
  
  /// Convenience initializer for UserDefaults storage
  public convenience init<Value: UserDefaultsStorable>(
    storage marker: UserDefaultsMarker,
    value: Value,
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: StaticString? = nil
  ) where S == UserDefaultsStorage<Value> {
    let userDefaults = marker.suite.flatMap { UserDefaults(suiteName: $0) } ?? UserDefaults.standard
    self.init(
      file,
      line,
      column,
      name: name,
      storage: UserDefaultsStorage(
        userDefaults: userDefaults,
        key: marker.key,
        defaultValue: value
      )
    )
  }
  
}

#endif