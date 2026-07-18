

@attached(accessor, names: named(get), named(set))
@attached(peer, names: prefixed(`$`))
public macro GraphComputed() = #externalMacro(module: "StateGraphMacro", type: "ComputedMacro")



@attached(peer)
public macro GraphIgnored() = #externalMacro(module: "StateGraphMacro", type: "IgnoredMacro")

/// Creates an in-memory `Stored` node and forwarding property accessors.
///
/// For persistent values, use `GraphUserDefault`; its projected reference
/// handle delegates dependency tracking to an internal `Stored` node.
///
/// Example:
/// ```swift
/// @GraphStored var count: Int = 0
/// ```
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(`$`))
public macro GraphStored() = #externalMacro(module: "StateGraphMacro", type: "GraphStoredMacro")

@_exported import os.lock
