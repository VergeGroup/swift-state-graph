import Foundation

/// A value that can be read from and written to `UserDefaults`.
///
/// Conforming values must define deterministic, synchronous conversion because
/// `GraphUserDefault` uses the restored value as the snapshot stored in its graph node.
public protocol UserDefaultsStorable: Equatable, Sendable {
  /// Returns the value stored for `key`, or `nil` when the key is absent or its
  /// value cannot be restored.
  @_spi(Internal)
  static func _getValueIfPresent(
    from userDefaults: UserDefaults,
    forKey key: String
  ) -> Self?

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
  // Public rather than SPI so that conformances in modules without the SPI import
  // can use it as their witness.
  public static func _getValueIfPresent(
    from userDefaults: UserDefaults,
    forKey key: String
  ) -> Self? {
    userDefaults.object(forKey: key) as? Self
  }

  @_spi(Internal)
  public static func _getValue(
    from userDefaults: UserDefaults,
    forKey key: String,
    defaultValue: Self
  ) -> Self {
    _getValueIfPresent(from: userDefaults, forKey: key) ?? defaultValue
  }
}

extension Bool: UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValueIfPresent(
    from userDefaults: UserDefaults,
    forKey key: String
  ) -> Bool? {
    guard userDefaults.object(forKey: key) != nil else {
      return nil
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
  public static func _getValueIfPresent(
    from userDefaults: UserDefaults,
    forKey key: String
  ) -> Int? {
    guard userDefaults.object(forKey: key) != nil else {
      return nil
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
  public static func _getValueIfPresent(
    from userDefaults: UserDefaults,
    forKey key: String
  ) -> Float? {
    guard userDefaults.object(forKey: key) != nil else {
      return nil
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
  public static func _getValueIfPresent(
    from userDefaults: UserDefaults,
    forKey key: String
  ) -> Double? {
    guard userDefaults.object(forKey: key) != nil else {
      return nil
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
  public static func _getValueIfPresent(
    from userDefaults: UserDefaults,
    forKey key: String
  ) -> String? {
    userDefaults.string(forKey: key)
  }

  @_spi(Internal)
  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Data: UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValueIfPresent(
    from userDefaults: UserDefaults,
    forKey key: String
  ) -> Data? {
    userDefaults.data(forKey: key)
  }

  @_spi(Internal)
  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Date: UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValueIfPresent(
    from userDefaults: UserDefaults,
    forKey key: String
  ) -> Date? {
    userDefaults.object(forKey: key) as? Date
  }

  @_spi(Internal)
  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension URL: UserDefaultsStorable {
  @_spi(Internal)
  public static func _getValueIfPresent(
    from userDefaults: UserDefaults,
    forKey key: String
  ) -> URL? {
    userDefaults.url(forKey: key)
  }

  @_spi(Internal)
  public func _setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

// Public rather than SPI so that Codable types in modules without the SPI import
// can conform through these witnesses.
extension UserDefaultsStorable where Self: Codable {
  public static func _getValueIfPresent(
    from userDefaults: UserDefaults,
    forKey key: String
  ) -> Self? {
    guard let data = userDefaults.data(forKey: key) else {
      return nil
    }

    return try? JSONDecoder().decode(Self.self, from: data)
  }

  public static func _getValue(
    from userDefaults: UserDefaults,
    forKey key: String,
    defaultValue: Self
  ) -> Self {
    _getValueIfPresent(from: userDefaults, forKey: key) ?? defaultValue
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
  public static func _getValueIfPresent(
    from userDefaults: UserDefaults,
    forKey key: String
  ) -> Self? {
    // Map instead of returning `Wrapped?` directly, which would promote a missing
    // value to `.some(nil)` and bypass the caller's default value.
    Wrapped._getValueIfPresent(from: userDefaults, forKey: key).map(Self.some)
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
