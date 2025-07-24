

@attached(accessor, names: named(get), named(set))
@attached(peer, names: prefixed(`$`))
public macro GraphComputed() = #externalMacro(module: "StateGraphMacro", type: "ComputedMacro")



@attached(peer)
public macro GraphIgnored() = #externalMacro(module: "StateGraphMacro", type: "IgnoredMacro")

// MARK: - Unified GraphStored Macro

/// Unified macro that supports different backing storage types
/// 
/// Usage:
/// ```swift
/// @GraphStored var count: Int = 0  // Memory storage (default)
/// @GraphStored(backed: .memory) var memoryCount: Int = 0
/// @GraphStored(backed: .userDefaults(key: "count")) var storedCount: Int = 0
/// @GraphStored(backed: .userDefaults(key: "theme", suite: "com.app")) var theme: String = "light"
/// ```

@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(`$`))
public macro GraphStored() = #externalMacro(module: "StateGraphMacro", type: "UnifiedStoredMacro")

@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(`$`))
public macro GraphStored(backed: MemoryMarker) = #externalMacro(module: "StateGraphMacro", type: "UnifiedStoredMacro")

@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(`$`))
public macro GraphStored(backed: UserDefaultsMarker) = #externalMacro(module: "StateGraphMacro", type: "UnifiedStoredMacro")


@_exported import os.lock
