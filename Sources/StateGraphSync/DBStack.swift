/// Runs queries and mutations with an application adapter.
public struct DBStack: Sendable {

  public struct MissingDependency: Error {

    public let dependencyType: Any.Type

  }

  fileprivate struct Adapter<Value: Sendable>: Sendable {
    let value: Value
  }

  @TaskLocal
  fileprivate static var currentAdapter: (any Sendable)?
  private let adapter: any Sendable

  public init<Value: Sendable>(adapter: Value) {
    self.adapter = Adapter(value: adapter)
  }

  public nonisolated(nonsending) func query<Q: Query>(_ query: Q) async throws -> Q.Output {
    try await execute {
      try await query.perform()
    }
  }

  public nonisolated(nonsending) func mutate<M: Mutation>(_ mutation: M) async throws -> M.Output {
    try await execute {
      try await mutation.perform()
    }
  }

  private nonisolated(nonsending) func execute<Output>(
    _ operation: nonisolated(nonsending) () async throws -> Output
  ) async rethrows -> Output {
    try await Self.$currentAdapter.withValue(adapter, operation: operation)
  }

}

/// Reads the adapter of the stack currently executing a query or mutation.
@propertyWrapper
public struct DBDependency<Value: Sendable>: Sendable {

  public init() {}

  public var wrappedValue: Value? {
    (DBStack.currentAdapter as? DBStack.Adapter<Value>)?.value
  }

  public var projectedValue: Self { self }

  /// Returns the adapter or throws if the executing stack did not provide the requested type.
  public func require() throws(DBStack.MissingDependency) -> Value {
    guard let value = wrappedValue else {
      throw DBStack.MissingDependency(dependencyType: Value.self)
    }
    return value
  }

}
