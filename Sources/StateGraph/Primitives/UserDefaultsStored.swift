import Foundation

// MARK: - UserDefaultsStored

/// A protocol for types that can be stored in UserDefaults
public protocol UserDefaultsStorable: Equatable, Sendable {
  @_spi(Internal)
  static func _getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Self) -> Self
  @_spi(Internal)
  func _setValue(to userDefaults: UserDefaults, forKey key: String)
}

extension UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Self) -> Self {
    if userDefaults.object(forKey: key) == nil {
      return defaultValue
    }
    return userDefaults.object(forKey: key) as? Self ?? defaultValue
  }
}

extension Bool: UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Bool) -> Bool {
    if userDefaults.object(forKey: key) == nil {
      return defaultValue
    }
    return userDefaults.bool(forKey: key)
  }
  @_spi(Internal)
  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Int: UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Int) -> Int {
    if userDefaults.object(forKey: key) == nil {
      return defaultValue
    }
    return userDefaults.integer(forKey: key)
  }
  @_spi(Internal)
  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Float: UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Float) -> Float {
    if userDefaults.object(forKey: key) == nil {
      return defaultValue
    }
    return userDefaults.float(forKey: key)
  }
  @_spi(Internal)
  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Double: UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Double) -> Double {
    if userDefaults.object(forKey: key) == nil {
      return defaultValue
    }
    return userDefaults.double(forKey: key)
  }
  @_spi(Internal)
  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension String: UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: String) -> String {
    return userDefaults.string(forKey: key) ?? defaultValue
  }
  @_spi(Internal)
  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Data: UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Data) -> Data {
    return userDefaults.data(forKey: key) ?? defaultValue
  }
  @_spi(Internal)
  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Date: UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Date) -> Date {
    return userDefaults.object(forKey: key) as? Date ?? defaultValue
  }
  @_spi(Internal)
  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

private enum Static {
  static let decoder = JSONDecoder()
  static let encoder = JSONEncoder()
}

extension UserDefaultsStorable where Self: Codable {
  public static func _getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Self) -> Self {
    guard let data = userDefaults.data(forKey: key) else {
      return defaultValue
    }
    do {
      return try Static.decoder.decode(Self.self, from: data)
    } catch {
      return defaultValue
    }
  }
  
  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    do {
      let data = try Static.encoder.encode(self)
      userDefaults.set(data, forKey: key)
    } catch {
      // If encoding fails, remove the key to avoid inconsistent state
      userDefaults.removeObject(forKey: key)
    }
  }
}

extension Optional: UserDefaultsStorable where Wrapped: UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Self) -> Self {
    if userDefaults.object(forKey: key) == nil {
      return defaultValue
    }
    // Try to get the wrapped value using a temporary dummy value
    // This is a workaround since we can't easily create a default Wrapped value
    let tempValue = userDefaults.object(forKey: key)
    if tempValue == nil {
      return nil
    }
    return tempValue as? Wrapped
  }
  @_spi(Internal)
  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    if let value = self {
      value._setValue(to: userDefaults, forKey: key)
    } else {
      userDefaults.removeObject(forKey: key)
    }
  }
}

//extension Array: UserDefaultsStorable where Element: UserDefaultsStorable {
//  public func setValue(to userDefaults: UserDefaults, forKey key: String) {
//    userDefaults.set(self, forKey: key)
//  }
//}
//
//extension Dictionary: UserDefaultsStorable where Key == String, Value: UserDefaultsStorable {
//  public func setValue(to userDefaults: UserDefaults, forKey key: String) {
//    userDefaults.set(self, forKey: key)
//  }
//}

/// A node that functions as an endpoint in a Directed Acyclic Graph (DAG) and persists its value to UserDefaults.
///
/// `UserDefaultsStored` can have its value set directly from the outside, and changes to its value
/// automatically propagate to dependent nodes. The value is automatically persisted to UserDefaults
/// and restored when the node is recreated.
///
/// - When value changes: Changes propagate to all dependent nodes and are persisted to UserDefaults
/// - When value is accessed: Dependencies are recorded and the value is loaded from UserDefaults if needed
public typealias UserDefaultsStored<Value: UserDefaultsStorable> = _Stored<Value, UserDefaultsStorage<Value>>
  
extension _Stored where S == UserDefaultsStorage<Value> {
  /// Initializes a UserDefaultsStored node with standard UserDefaults.
  ///
  /// - Parameters:
  ///   - file: The file where the node is created (defaults to current file)
  ///   - line: The line number where the node is created (defaults to current line)
  ///   - column: The column number where the node is created (defaults to current column)
  ///   - group: The group name of the node (defaults to nil)
  ///   - name: The name of the node (defaults to nil)
  ///   - key: The UserDefaults key to store the value
  ///   - defaultValue: The default value if no value exists in UserDefaults
  public convenience init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: StaticString? = nil,
    key: String,
    defaultValue: Value
  ) {
    let storage = UserDefaultsStorage(
      userDefaults: .standard,
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
  
  /// Initializes a UserDefaultsStored node with a specific UserDefaults suite.
  ///
  /// - Parameters:
  ///   - file: The file where the node is created (defaults to current file)
  ///   - line: The line number where the node is created (defaults to current line)
  ///   - column: The column number where the node is created (defaults to current column)
  ///   - group: The group name of the node (defaults to nil)
  ///   - name: The name of the node (defaults to nil)
  ///   - suite: The UserDefaults suite name
  ///   - key: The UserDefaults key to store the value
  ///   - defaultValue: The default value if no value exists in UserDefaults
  public convenience init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: StaticString? = nil,
    suite: String,
    key: String,
    defaultValue: Value
  ) {
    let storage = UserDefaultsStorage(
      userDefaults: UserDefaults(suiteName: suite) ?? .standard,
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
