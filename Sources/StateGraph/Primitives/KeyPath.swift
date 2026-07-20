import Observation

/// Lazily owns the Apple Observation registrar associated with one graph node.
///
/// The owning node must serialize access to this storage with its node lock. Keeping the
/// registrar scoped to one node ensures that registrations are released with that node.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
struct NodeObservationRegistrar: ~Copyable, Sendable {

  private var registrar: ObservationRegistrar?

  var current: ObservationRegistrar? {
    registrar
  }

  var isInitialized: Bool {
    registrar != nil
  }

  mutating func initializeIfNeeded() -> ObservationRegistrar {
    if let registrar {
      return registrar
    }

    let registrar = ObservationRegistrar()
    self.registrar = registrar
    return registrar
  }
}

/// A type-specific subject that gives every node registrar a readable property key path.
///
/// Node identity is carried by the owning `NodeObservationRegistrar`, so the key path only
/// needs to describe the observed value. For example, a stored integer prints as
/// `\NodeObservationRoot<Stored<Int>>.wrappedValue` instead of embedding a memory address.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
struct NodeObservationRoot<Owner: AnyObject>: Observable, Sendable {

  let wrappedValue: Void = ()
}
