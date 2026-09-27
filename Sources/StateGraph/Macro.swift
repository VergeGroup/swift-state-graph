

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

/// Zero-size storage used by `@GraphStored` to work around a Swift compiler bug.
///
/// After an init accessor with an empty `initializes` list runs, an initializer
/// that throws or returns `nil` before `self` is fully initialized can destroy
/// stored properties twice. This definite-initialization bug was reproduced
/// with Swift 6.4. The marker supplies an initialization target while assignments
/// continue to use the same `Stored` node.
///
/// This type is public so generated code in client modules can use the workaround.
public struct GraphStoredInitMarker: Hashable, Sendable {
  public init() {}
}

@_exported import os.lock
