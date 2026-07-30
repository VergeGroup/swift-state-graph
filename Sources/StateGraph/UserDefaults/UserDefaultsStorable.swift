import Foundation

/// A value that can be read from and written to `UserDefaults`.
///
/// Conforming values must define deterministic, synchronous conversion because
/// `GraphUserDefault` uses the restored value as the snapshot stored in its graph node.
public protocol UserDefaultsStorable: Equatable, Sendable {
  @_spi(Internal)
  static func _getValue(
    from userDefaults: UserDefaults,
    forKey key: String,
    defaultValue: Self
  ) -> Self

  @_spi(Internal)
  func _setValue(to userDefaults: UserDefaults, forKey key: String)
}

extension UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValue(
    from userDefaults: UserDefaults,
    forKey key: String,
    defaultValue: Self
  ) -> Self {
    guard userDefaults.object(forKey: key) != nil else {
      return defaultValue
    }
    return userDefaults.object(forKey: key) as? Self ?? defaultValue
  }
}

extension Bool: UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValue(
    from userDefaults: UserDefaults,
    forKey key: String,
    defaultValue: Bool
  ) -> Bool {
    guard userDefaults.object(forKey: key) != nil else {
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
  public static func _getValue(
    from userDefaults: UserDefaults,
    forKey key: String,
    defaultValue: Int
  ) -> Int {
    guard userDefaults.object(forKey: key) != nil else {
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
  public static func _getValue(
    from userDefaults: UserDefaults,
    forKey key: String,
    defaultValue: Float
  ) -> Float {
    guard userDefaults.object(forKey: key) != nil else {
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
  public static func _getValue(
    from userDefaults: UserDefaults,
    forKey key: String,
    defaultValue: Double
  ) -> Double {
    guard userDefaults.object(forKey: key) != nil else {
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
  public static func _getValue(
    from userDefaults: UserDefaults,
    forKey key: String,
    defaultValue: String
  ) -> String {
    userDefaults.string(forKey: key) ?? defaultValue
  }

  @_spi(Internal)
  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Data: UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValue(
    from userDefaults: UserDefaults,
    forKey key: String,
    defaultValue: Data
  ) -> Data {
    userDefaults.data(forKey: key) ?? defaultValue
  }

  @_spi(Internal)
  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Date: UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValue(
    from userDefaults: UserDefaults,
    forKey key: String,
    defaultValue: Date
  ) -> Date {
    userDefaults.object(forKey: key) as? Date ?? defaultValue
  }

  @_spi(Internal)
  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension URL: UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValue(
    from userDefaults: UserDefaults,
    forKey key: String,
    defaultValue: URL
  ) -> URL {
    userDefaults.url(forKey: key) ?? defaultValue
  }

  @_spi(Internal)
  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension UserDefaultsStorable where Self: Codable {
  public static func _getValue(
    from userDefaults: UserDefaults,
    forKey key: String,
    defaultValue: Self
  ) -> Self {
    guard let data = userDefaults.data(forKey: key) else {
      return defaultValue
    }

    return (try? JSONDecoder().decode(Self.self, from: data)) ?? defaultValue
  }

  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    guard let data = try? JSONEncoder().encode(self) else {
      userDefaults.removeObject(forKey: key)
      return
    }
    userDefaults.set(data, forKey: key)
  }
}

extension Optional: UserDefaultsStorable where Wrapped: UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValue(
    from userDefaults: UserDefaults,
    forKey key: String,
    defaultValue: Self
  ) -> Self {
    guard userDefaults.object(forKey: key) != nil else {
      return defaultValue
    }
    return userDefaults.object(forKey: key) as? Wrapped
  }

  @_spi(Internal)
  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    guard let value = self else {
      userDefaults.removeObject(forKey: key)
      return
    }
    value._setValue(to: userDefaults, forKey: key)
  }
}
