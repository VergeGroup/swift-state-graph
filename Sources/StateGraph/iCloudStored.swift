import Foundation

// MARK: - iCloudStored

/// A protocol for types that can be stored in iCloud using NSUbiquitousKeyValueStore
public protocol iCloudStorable: Equatable, Sendable {
  @_spi(Internal)
  static func _getValue(from store: NSUbiquitousKeyValueStore, forKey key: String, defaultValue: Self) -> Self
  @_spi(Internal)
  func _setValue(to store: NSUbiquitousKeyValueStore, forKey key: String)
}

extension iCloudStorable {
  @_spi(Internal)
  public static func _getValue(from store: NSUbiquitousKeyValueStore, forKey key: String, defaultValue: Self) -> Self {
    if store.object(forKey: key) == nil {
      return defaultValue
    }
    return store.object(forKey: key) as? Self ?? defaultValue
  }
}

extension Bool: iCloudStorable {
  @_spi(Internal)
  public static func _getValue(from store: NSUbiquitousKeyValueStore, forKey key: String, defaultValue: Bool) -> Bool {
    if store.object(forKey: key) == nil {
      return defaultValue
    }
    return store.bool(forKey: key)
  }
  @_spi(Internal)
  public func _setValue(to store: NSUbiquitousKeyValueStore, forKey key: String) {
    store.set(self, forKey: key)
    store.synchronize()
  }
}

extension Int: iCloudStorable {
  @_spi(Internal)
  public static func _getValue(from store: NSUbiquitousKeyValueStore, forKey key: String, defaultValue: Int) -> Int {
    if store.object(forKey: key) == nil {
      return defaultValue
    }
    return Int(store.longLong(forKey: key))
  }
  @_spi(Internal)
  public func _setValue(to store: NSUbiquitousKeyValueStore, forKey key: String) {
    store.set(Int64(self), forKey: key)
    store.synchronize()
  }
}

extension Float: iCloudStorable {
  @_spi(Internal)
  public static func _getValue(from store: NSUbiquitousKeyValueStore, forKey key: String, defaultValue: Float) -> Float {
    if store.object(forKey: key) == nil {
      return defaultValue
    }
    return Float(store.double(forKey: key))
  }
  @_spi(Internal)
  public func _setValue(to store: NSUbiquitousKeyValueStore, forKey key: String) {
    store.set(Double(self), forKey: key)
    store.synchronize()
  }
}

extension Double: iCloudStorable {
  @_spi(Internal)
  public static func _getValue(from store: NSUbiquitousKeyValueStore, forKey key: String, defaultValue: Double) -> Double {
    if store.object(forKey: key) == nil {
      return defaultValue
    }
    return store.double(forKey: key)
  }
  @_spi(Internal)
  public func _setValue(to store: NSUbiquitousKeyValueStore, forKey key: String) {
    store.set(self, forKey: key)
    store.synchronize()
  }
}

extension String: iCloudStorable {
  @_spi(Internal)
  public static func _getValue(from store: NSUbiquitousKeyValueStore, forKey key: String, defaultValue: String) -> String {
    return store.string(forKey: key) ?? defaultValue
  }
  @_spi(Internal)
  public func _setValue(to store: NSUbiquitousKeyValueStore, forKey key: String) {
    store.set(self, forKey: key)
    store.synchronize()
  }
}

extension Data: iCloudStorable {
  @_spi(Internal)
  public static func _getValue(from store: NSUbiquitousKeyValueStore, forKey key: String, defaultValue: Data) -> Data {
    return store.data(forKey: key) ?? defaultValue
  }
  @_spi(Internal)
  public func _setValue(to store: NSUbiquitousKeyValueStore, forKey key: String) {
    store.set(self, forKey: key)
    store.synchronize()
  }
}

extension Date: iCloudStorable {
  @_spi(Internal)
  public static func _getValue(from store: NSUbiquitousKeyValueStore, forKey key: String, defaultValue: Date) -> Date {
    return store.object(forKey: key) as? Date ?? defaultValue
  }
  @_spi(Internal)
  public func _setValue(to store: NSUbiquitousKeyValueStore, forKey key: String) {
    store.set(self, forKey: key)
    store.synchronize()
  }
}

private enum Static {
  static let decoder = JSONDecoder()
  static let encoder = JSONEncoder()
}

extension iCloudStorable where Self: Codable {
  public static func _getValue(from store: NSUbiquitousKeyValueStore, forKey key: String, defaultValue: Self) -> Self {
    guard let data = store.data(forKey: key) else {
      return defaultValue
    }
    do {
      return try Static.decoder.decode(Self.self, from: data)
    } catch {
      return defaultValue
    }
  }
  
  public func _setValue(to store: NSUbiquitousKeyValueStore, forKey key: String) {
    do {
      let data = try Static.encoder.encode(self)
      store.set(data, forKey: key)
      store.synchronize()
    } catch {
      // If encoding fails, remove the key to avoid inconsistent state
      store.removeObject(forKey: key)
      store.synchronize()
    }
  }
}

extension Optional: iCloudStorable where Wrapped: iCloudStorable {
  @_spi(Internal)
  public static func _getValue(from store: NSUbiquitousKeyValueStore, forKey key: String, defaultValue: Self) -> Self {
    if store.object(forKey: key) == nil {
      return defaultValue
    }
    // Try to get the wrapped value using a temporary dummy value
    let tempValue = store.object(forKey: key)
    if tempValue == nil {
      return nil
    }
    return tempValue as? Wrapped
  }
  @_spi(Internal)
  public func _setValue(to store: NSUbiquitousKeyValueStore, forKey key: String) {
    if let value = self {
      value._setValue(to: store, forKey: key)
    } else {
      store.removeObject(forKey: key)
      store.synchronize()
    }
  }
}

/// A node that functions as an endpoint in a Directed Acyclic Graph (DAG) and persists its value to iCloud.
///
/// `iCloudStored` can have its value set directly from the outside, and changes to its value
/// automatically propagate to dependent nodes. The value is automatically persisted to iCloud
/// and restored when the node is recreated.
///
/// - When value changes: Changes propagate to all dependent nodes and are persisted to iCloud
/// - When value is accessed: Dependencies are recorded and the value is loaded from iCloud if needed
/// - When other devices change the value: The local value is automatically updated
public typealias iCloudStored<Value: iCloudStorable> = _Stored<Value, iCloudStorage<Value>>
  
extension _Stored where S == iCloudStorage<Value> {
  /// Initializes an iCloudStored node.
  ///
  /// - Parameters:
  ///   - file: The file where the node is created (defaults to current file)
  ///   - line: The line number where the node is created (defaults to current line)
  ///   - column: The column number where the node is created (defaults to current column)
  ///   - name: The name of the node (defaults to nil)
  ///   - key: The iCloud key to store the value
  ///   - defaultValue: The default value if no value exists in iCloud
  public convenience init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: StaticString? = nil,
    key: String,
    defaultValue: Value
  ) {
    let storage = iCloudStorage(
      store: NSUbiquitousKeyValueStore.default,
      key: key,
      defaultValue: defaultValue
    )
    self.init(
      file,
      line,
      column,
      name: name,
      storage: storage
    )
  }
} 