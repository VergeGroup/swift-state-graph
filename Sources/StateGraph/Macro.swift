

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
@attached(peer, names: prefixed(`$`), prefixed(`$__init_`))
public macro GraphStored() = #externalMacro(module: "StateGraphMacro", type: "GraphStoredMacro")

/// Zero-size storage that `@GraphStored` init accessors initialize.
///
/// An init accessor that only accesses the existing `Stored` node would have an
/// empty `initializes` list. Definite initialization then destroys the wrong
/// stored property when an initializer throws or returns `nil` before every
/// stored property is initialized. Initializing this marker keeps the generated
/// init accessors out of that path while the `Stored` node keeps its identity.
public struct GraphStoredInitMarker: Hashable, Sendable {
  public init() {}
}

@_exported import os.lock
