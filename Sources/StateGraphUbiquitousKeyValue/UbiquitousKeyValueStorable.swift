import Foundation

/// A value that can be represented in an iCloud key-value store.
///
/// Conforming values convert synchronously to and from property-list values.
/// `GraphUbiquitousKeyValue` uses the decoded result as the snapshot owned by
/// its internal `StateGraph.Stored` node.
public protocol UbiquitousKeyValueStorable: Equatable, Sendable {
  /// Decodes one property-list value from the iCloud key-value store.
  ///
  /// Return `nil` when `object` doesn't contain a valid representation of
  /// `Self`. The property wrapper then uses its declared default value.
  @_spi(Internal)
  static func _decodeUbiquitousKeyValue(from object: Any) -> Self?

  /// Encodes this value as an iCloud property-list value.
  ///
  /// Returning `nil` removes the key. This is also how an optional `nil`
  /// value is represented because property lists don't contain null values.
  @_spi(Internal)
  func _encodeUbiquitousKeyValue() -> Any?
}

extension Bool: UbiquitousKeyValueStorable {
  @_spi(Internal)
  public static func _decodeUbiquitousKeyValue(from object: Any) -> Bool? {
    if let value = object as? Bool {
      return value
    }
    return (object as? NSNumber)?.boolValue
  }

  @_spi(Internal)
  public func _encodeUbiquitousKeyValue() -> Any? {
    self
  }
}

extension Int: UbiquitousKeyValueStorable {
  @_spi(Internal)
  public static func _decodeUbiquitousKeyValue(from object: Any) -> Int? {
    if let value = object as? Int {
      return value
    }
    guard let number = object as? NSNumber else { return nil }
    return Int(exactly: number.int64Value)
  }

  @_spi(Internal)
  public func _encodeUbiquitousKeyValue() -> Any? {
    Int64(self)
  }
}

extension Int64: UbiquitousKeyValueStorable {
  @_spi(Internal)
  public static func _decodeUbiquitousKeyValue(from object: Any) -> Int64? {
    if let value = object as? Int64 {
      return value
    }
    return (object as? NSNumber)?.int64Value
  }

  @_spi(Internal)
  public func _encodeUbiquitousKeyValue() -> Any? {
    self
  }
}

extension Float: UbiquitousKeyValueStorable {
  @_spi(Internal)
  public static func _decodeUbiquitousKeyValue(from object: Any) -> Float? {
    if let value = object as? Float {
      return value
    }
    return (object as? NSNumber)?.floatValue
  }

  @_spi(Internal)
  public func _encodeUbiquitousKeyValue() -> Any? {
    Double(self)
  }
}

extension Double: UbiquitousKeyValueStorable {
  @_spi(Internal)
  public static func _decodeUbiquitousKeyValue(from object: Any) -> Double? {
    if let value = object as? Double {
      return value
    }
    return (object as? NSNumber)?.doubleValue
  }

  @_spi(Internal)
  public func _encodeUbiquitousKeyValue() -> Any? {
    self
  }
}

extension String: UbiquitousKeyValueStorable {
  @_spi(Internal)
  public static func _decodeUbiquitousKeyValue(from object: Any) -> String? {
    object as? String
  }

  @_spi(Internal)
  public func _encodeUbiquitousKeyValue() -> Any? {
    self
  }
}

extension Data: UbiquitousKeyValueStorable {
  @_spi(Internal)
  public static func _decodeUbiquitousKeyValue(from object: Any) -> Data? {
    object as? Data
  }

  @_spi(Internal)
  public func _encodeUbiquitousKeyValue() -> Any? {
    self
  }
}

extension Date: UbiquitousKeyValueStorable {
  @_spi(Internal)
  public static func _decodeUbiquitousKeyValue(from object: Any) -> Date? {
    object as? Date
  }

  @_spi(Internal)
  public func _encodeUbiquitousKeyValue() -> Any? {
    self
  }
}

extension Array: UbiquitousKeyValueStorable where Element: UbiquitousKeyValueStorable {
  @_spi(Internal)
  public static func _decodeUbiquitousKeyValue(from object: Any) -> [Element]? {
    guard let objects = object as? [Any] else { return nil }

    var result: [Element] = []
    result.reserveCapacity(objects.count)

    for object in objects {
      guard let value = Element._decodeUbiquitousKeyValue(from: object) else {
        return nil
      }
      result.append(value)
    }

    return result
  }

  @_spi(Internal)
  public func _encodeUbiquitousKeyValue() -> Any? {
    var result: [Any] = []
    result.reserveCapacity(count)

    for value in self {
      guard let object = value._encodeUbiquitousKeyValue() else {
        return nil
      }
      result.append(object)
    }

    return result
  }
}

extension Dictionary: UbiquitousKeyValueStorable
where Key == String, Value: UbiquitousKeyValueStorable {
  @_spi(Internal)
  public static func _decodeUbiquitousKeyValue(from object: Any) -> [String: Value]? {
    guard let objects = object as? [String: Any] else { return nil }

    var result: [String: Value] = [:]
    result.reserveCapacity(objects.count)

    for (key, object) in objects {
      guard let value = Value._decodeUbiquitousKeyValue(from: object) else {
        return nil
      }
      result[key] = value
    }

    return result
  }

  @_spi(Internal)
  public func _encodeUbiquitousKeyValue() -> Any? {
    var result: [String: Any] = [:]
    result.reserveCapacity(count)

    for (key, value) in self {
      guard let object = value._encodeUbiquitousKeyValue() else {
        return nil
      }
      result[key] = object
    }

    return result
  }
}

extension UbiquitousKeyValueStorable where Self: Codable {
  public static func _decodeUbiquitousKeyValue(from object: Any) -> Self? {
    guard let data = object as? Data else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }

  public func _encodeUbiquitousKeyValue() -> Any? {
    try? JSONEncoder().encode(self)
  }
}

extension Optional: UbiquitousKeyValueStorable
where Wrapped: UbiquitousKeyValueStorable {
  @_spi(Internal)
  public static func _decodeUbiquitousKeyValue(from object: Any) -> Self? {
    guard let value = Wrapped._decodeUbiquitousKeyValue(from: object) else {
      return nil
    }
    return .some(value)
  }

  @_spi(Internal)
  public func _encodeUbiquitousKeyValue() -> Any? {
    switch self {
    case .some(let value):
      value._encodeUbiquitousKeyValue()
    case .none:
      nil
    }
  }
}
