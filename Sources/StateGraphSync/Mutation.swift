/// A write operation executed with the adapter of its database stack.
public protocol Mutation<Output> {

  associatedtype Output

  nonisolated(nonsending) func perform() async throws -> Output

}
