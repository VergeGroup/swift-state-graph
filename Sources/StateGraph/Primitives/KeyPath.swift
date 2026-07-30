import Observation

/// A type-specific subject that gives every node registrar a readable property key path.
///
/// Node identity is carried by each node's own `ObservationRegistrar`, so the key path
/// only needs to describe the observed value. For example, a stored integer prints as
/// `\NodeObservationRoot<Stored<Int>>.wrappedValue` instead of embedding a memory address.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
struct NodeObservationRoot<Owner: AnyObject>: Observable, Sendable {

  let wrappedValue: Void = ()
}
