

@attached(accessor, names: named(get), named(set))
@attached(peer, names: prefixed(`$`))
public macro GraphComputed() = #externalMacro(module: "StateGraphMacro", type: "ComputedMacro")



@attached(peer)
public macro GraphIgnored() = #externalMacro(module: "StateGraphMacro", type: "IgnoredMacro")

// MARK: - Backing Storage Types

/// Represents different types of backing storage for GraphStored properties
public enum GraphStorageBacking {
  /// In-memory storage (default)
  case memory
  /// UserDefaults storage with a key
  case userDefaults(key: String)
  /// UserDefaults storage with suite and key
  case userDefaults(suite: String, key: String)
  /// UserDefaults storage with suite, key, and name
  case userDefaults(suite: String, key: String, name: String)
  /// SwiftData storage with CloudKit sync
  case swiftData(key: String)
  /// SwiftData storage with CloudKit sync and custom model context
  case swiftData(key: String, context: Any)
}

// MARK: - Unified GraphStored Macro

/// Unified macro that supports different backing storage types
/// 
/// Usage:
/// ```swift
/// @GraphStored var count: Int = 0  // Memory storage (default)
/// @GraphStored(backed: .userDefaults(key: "count")) var storedCount: Int = 0
/// @GraphStored(backed: .userDefaults(suite: "com.app", key: "theme")) var theme: String = "light"
/// @GraphStored(backed: .swiftData(key: "settings")) var settings: MySettings = MySettings()
/// ```
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(`$`))
public macro GraphStored(backed: GraphStorageBacking = .memory) = #externalMacro(module: "StateGraphMacro", type: "UnifiedStoredMacro")

@_exported import os.lock
