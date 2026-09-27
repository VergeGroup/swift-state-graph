/// Identifies a synchronous graph context in which mutation is unsupported.
///
/// DEBUG builds install this marker around user-provided closures that must be
/// side-effect free. Non-DEBUG builds omit marker storage and checking so the
/// unsupported-operation diagnostic adds no release runtime overhead.
enum GraphMutationProhibition: Sendable {
  case computedDescriptor
  case storedComparator
  case unsafeModification

#if DEBUG
  fileprivate var contextDescription: String {
    switch self {
    case .computedDescriptor:
      "a Computed descriptor"
    case .storedComparator:
      "a Stored shouldNotify comparator"
    case .unsafeModification:
      "Stored.unsafeModify"
    }
  }
#endif
}

/// Identifies one descriptor invocation that may initialize its newly created nodes.
///
/// Nodes keep a weak reference to this identity so permission expires when the
/// invocation ends. It owns no graph nodes. Nested evaluations receive independent
/// identities, and comparators and other read-only callbacks suspend the enclosing permission.
final class StoredInitializationScope: Sendable {}

/// Asserts in DEBUG when a mutation enters a graph context that must be read-only.
@inline(__always)
func assertGraphMutationAllowed(_ operation: String) {
#if DEBUG
  guard let prohibition = ThreadLocal.graphMutationProhibition.value else { return }

  preconditionFailure(
    "\(operation) is not allowed during \(prohibition.contextDescription). Move graph mutations outside that closure."
  )
#endif
}

/// Runs a read-only graph closure with optional permission to initialize new nodes.
///
/// Initialization scopes are active in every build. Mutation diagnostics use a
/// separate DEBUG-only marker.
@inline(__always)
func withGraphMutationProhibited<Result>(
  _ prohibition: GraphMutationProhibition,
  allowingStoredInitialization: Bool = false,
  _ body: () -> Result
) -> Result {
  let previousInitializationScope = ThreadLocal.storedInitializationScope.replaceValue(
    allowingStoredInitialization ? StoredInitializationScope() : nil
  )
  defer {
    ThreadLocal.storedInitializationScope.replaceValue(previousInitializationScope)
  }

#if DEBUG
  let previousProhibition = ThreadLocal.graphMutationProhibition.replaceValue(prohibition)
  defer {
    ThreadLocal.graphMutationProhibition.replaceValue(previousProhibition)
  }
  return body()
#else
  return body()
#endif
}

/// Runs a throwing read-only closure with initialization permission suspended.
/// Mutation diagnostics use a separate DEBUG-only marker.
@inline(__always)
func withGraphMutationProhibited<Result, Failure: Error>(
  _ prohibition: GraphMutationProhibition,
  _ body: () throws(Failure) -> Result
) throws(Failure) -> Result {
  // A mutation callback must not inherit permission from an enclosing descriptor.
  let previousInitializationScope = ThreadLocal.storedInitializationScope.replaceValue(nil)
  defer {
    ThreadLocal.storedInitializationScope.replaceValue(previousInitializationScope)
  }

#if DEBUG
  return try ThreadLocal.graphMutationProhibition.withValue(
    prohibition,
    perform: body
  )
#else
  return try body()
#endif
}
