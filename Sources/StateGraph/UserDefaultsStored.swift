import Foundation

// MARK: - UserDefaultsStored

/// A protocol for types that can be stored in UserDefaults
public protocol UserDefaultsStorable: Sendable {
  @_spi(Internal)
  static func getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Self) -> Self
  @_spi(Internal)
  func setValue(to userDefaults: UserDefaults, forKey key: String)
}

extension UserDefaultsStorable {
  @_spi(Internal)
  public static func getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Self) -> Self {
    if userDefaults.object(forKey: key) == nil {
      return defaultValue
    }
    return userDefaults.object(forKey: key) as? Self ?? defaultValue
  }
}

extension Bool: UserDefaultsStorable {
  @_spi(Internal)
  public static func getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Bool) -> Bool {
    if userDefaults.object(forKey: key) == nil {
      return defaultValue
    }
    return userDefaults.bool(forKey: key)
  }
  @_spi(Internal)
  public func setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Int: UserDefaultsStorable {
  @_spi(Internal)
  public static func getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Int) -> Int {
    if userDefaults.object(forKey: key) == nil {
      return defaultValue
    }
    return userDefaults.integer(forKey: key)
  }
  @_spi(Internal)
  public func setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Float: UserDefaultsStorable {
  @_spi(Internal)
  public static func getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Float) -> Float {
    if userDefaults.object(forKey: key) == nil {
      return defaultValue
    }
    return userDefaults.float(forKey: key)
  }
  @_spi(Internal)
  public func setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Double: UserDefaultsStorable {
  @_spi(Internal)
  public static func getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Double) -> Double {
    if userDefaults.object(forKey: key) == nil {
      return defaultValue
    }
    return userDefaults.double(forKey: key)
  }
  @_spi(Internal)
  public func setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension String: UserDefaultsStorable {
  @_spi(Internal)
  public static func getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: String) -> String {
    return userDefaults.string(forKey: key) ?? defaultValue
  }
  @_spi(Internal)
  public func setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Data: UserDefaultsStorable {
  @_spi(Internal)
  public static func getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Data) -> Data {
    return userDefaults.data(forKey: key) ?? defaultValue
  }
  @_spi(Internal)
  public func setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Date: UserDefaultsStorable {
  @_spi(Internal)
  public static func getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Date) -> Date {
    return userDefaults.object(forKey: key) as? Date ?? defaultValue
  }
  @_spi(Internal)
  public func setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
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
public typealias UserDefaultsStored<Value: UserDefaultsStorable> = _StoredNode<Value, UserDefaultsStorage<Value>>
  
extension _StoredNode where S == UserDefaultsStorage<Value> {
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
    group: String? = nil,
    name: String? = nil,
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
      group: group,
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
    group: String? = nil,
    name: String? = nil,
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
      group: group,
      name: name,
      storage: storage
    )
  }
}
