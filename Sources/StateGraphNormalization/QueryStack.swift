/// An application request and the type of its resolved value.
public protocol Query<Output> {
  associatedtype Output
}

/// Resolves use-case queries against the dependencies owned by one stack.
public struct QueryStack<Dependencies: Sendable>: Sendable {

  /// The stack has no resolver for the requested concrete query type.
  public struct MissingResolver: Error {
    /// The concrete type passed to `resolve(_:)`.
    public let queryType: Any.Type
  }

  private typealias Resolver<Q: Query> = @Sendable (Q, Dependencies) async throws -> Q.Output

  private let dependencies: Dependencies
  private var resolvers: [ObjectIdentifier: any Sendable] = [:]

  /// Creates an empty stack with the dependencies passed to every resolver.
  public init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  /// Installs a resolver in this stack value, replacing any resolver for the same type.
  public mutating func register<Q: Query>(
    _: Q.Type,
    resolve: @escaping @Sendable (Q, Dependencies) async throws -> Q.Output
  ) {
    resolvers[ObjectIdentifier(Q.self)] = resolve
  }

  /// Dispatches by the static query type. Its resolver controls I/O and storage.
  public func resolve<Q: Query>(_ query: Q) async throws -> Q.Output {
    guard let resolver = resolvers[ObjectIdentifier(Q.self)] as? Resolver<Q> else {
      throw MissingResolver(queryType: Q.self)
    }
    return try await resolver(query, dependencies)
  }

}
