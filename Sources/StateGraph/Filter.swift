
/**
 A protocol for filtering values in node observation.

 Filters allow you to control which values trigger change notifications by implementing
 custom filtering logic. The filter's `send` method is called with each new value and
 can decide whether to pass it through or suppress the notification.
 */
public protocol Filter<Value> {

  associatedtype Value

  /// Processes a value and returns it if it should be passed to the handler, or nil to suppress the notification.
  /// - Parameter value: The new value from the node
  /// - Returns: The value to pass to the change handler, or nil to suppress
  ///   the handler call. Returning nil does NOT affect Observation notifications
  ///   (used by SwiftUI) - those are triggered at the node level when the node
  ///   becomes potentially dirty.
  mutating func send(value: Value) -> Value?
}

/**
 A filter that passes through all values without any filtering.

 This is the default filter used when no explicit filter is specified.
 Every value change will trigger the onChange handler.
 */
public struct PassthroughFilter<Value>: Filter {

  public func send(value: Value) -> Value? {
    return value
  }

  public init() {}
}

/**
 A filter that only passes through values that are different from the previous value.

 This filter uses equality comparison to suppress duplicate onChange handler calls,
 which is useful for avoiding unnecessary work when the actual value hasn't changed.

 Note: This only affects onChange handler calls. SwiftUI and other Observation
 consumers will still receive notifications when the node becomes potentially dirty,
 allowing them to check for updates. This is the correct behavior because:
 - SwiftUI needs to know a value *might* have changed to trigger re-evaluation
 - onChange handlers should only run when values *actually* changed

 ```swift
 node.onChange(DistinctFilter<String>()) { value in
   // Only called when value actually changes
   print("New value: \(value)")
 }
 ```
 */
public struct DistinctFilter<Value: Equatable>: Filter {

  private var lastValue: Value?

  public mutating func send(value: Value) -> Value? {
    guard value != lastValue else { return nil }
    lastValue = value
    return value
  }

  public init() {}
}
