/// Caches a computed property's body in a lazily created `Computed` node.
///
/// Reads track graph dependencies and reuse the cached value until a dependency changes.
/// The projected `$value` property exposes the node. Supports class instance, global,
/// and static properties with a synchronous, read-only body. Requires Swift 6.4.
///
/// ```swift
/// @GraphComputed var doubled: Int { count * 2 }
/// ```
@attached(peer, names: prefixed(`$`), prefixed(_), prefixed(_compute_))
@attached(body)
public macro GraphComputed() = #externalMacro(module: "StateGraphMacro", type: "GraphComputedMacro")

/// Exposes the value of a `Computed` node that you initialize through `$value`.
///
/// Use this form when the node needs an explicit capture list, a custom computation
/// context, or ownership independent of the enclosing model. Declare the property
/// without a body and initialize its projected node in the enclosing initializer.
///
/// ```swift
/// @GraphComputedNode var doubled: Int
/// // In init: $doubled = .init { [count = $count] _ in count.wrappedValue * 2 }
/// ```
@attached(accessor, names: named(get))
@attached(peer, names: prefixed(`$`))
public macro GraphComputedNode() = #externalMacro(module: "StateGraphMacro", type: "GraphComputedNodeMacro")

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
