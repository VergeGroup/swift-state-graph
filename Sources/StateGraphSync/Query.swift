/// A request executed with the adapter of its database stack.
public protocol Query<Output> {

  associatedtype Output

  nonisolated(nonsending) func perform() async throws -> Output

}
