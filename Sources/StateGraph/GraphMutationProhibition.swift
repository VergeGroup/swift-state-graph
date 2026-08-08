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

/// Runs a closure under a DEBUG-only marker that diagnoses graph mutation.
@inline(__always)
func withGraphMutationProhibited<Result>(
  _ prohibition: GraphMutationProhibition,
  _ body: () -> Result
) -> Result {
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

/// Runs a throwing closure under a DEBUG-only marker that diagnoses graph mutation.
@inline(__always)
func withGraphMutationProhibited<Result, Failure: Error>(
  _ prohibition: GraphMutationProhibition,
  _ body: () throws(Failure) -> Result
) throws(Failure) -> Result {
#if DEBUG
  try ThreadLocal.graphMutationProhibition.withValue(
    prohibition,
    perform: body
  )
#else
  try body()
#endif
}
