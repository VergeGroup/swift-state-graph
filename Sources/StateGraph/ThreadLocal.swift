
import Foundation

struct ThreadLocalValue<Value>: ~Copyable, Sendable {

  var value: Value? {
    get {
      Thread.current.threadDictionary[key] as? Value
    }
  }

  let key: String

  init(key: String) {
    self.key = key
  }

  /// Replaces the current value and returns the value that was installed before it.
  ///
  /// The typed-throws transaction entry point uses this primitive instead of a
  /// throwing closure wrapper so its failure type remains unchanged.
  @discardableResult
  func replaceValue(_ value: Value?) -> Value? {
    let oldValue = self.value
    setValue(value)
    return oldValue
  }

  private func setValue(_ value: Value?) {
    if let value {
      Thread.current.threadDictionary[key] = value
    } else {
      Thread.current.threadDictionary.removeObject(forKey: key)
    }
  }

  func withValue<R, Failure: Error>(
    _ value: Value?,
    perform: () throws(Failure) -> R
  ) throws(Failure) -> R {
    let oldValue = replaceValue(value)
    defer {
      replaceValue(oldValue)
    }
    return try perform()
  }

}

enum ThreadLocal: Sendable {

  static let registration: ThreadLocalValue<TrackingRegistration> = .init(key: "org.vergegroup.state-graph.registration")
  static let subscriptions: ThreadLocalValue<Subscriptions> = .init(key: "org.vergegroup.state-graph.subscriptions")
  static let currentNode: ThreadLocalValue<any TypeErasedNode> = .init(key: "org.vergegroup.state-graph.currentNode")
  static let currentCancellable: ThreadLocalValue<GraphTrackingCancellable> = .init(key: "org.vergegroup.state-graph.currentCancellable")
  static let graphTransaction: ThreadLocalValue<GraphTransactionContext> = .init(key: "org.vergegroup.state-graph.transaction")
  static let graphTransactionReadScope: ThreadLocalValue<GraphTransactionReadScope> = .init(key: "org.vergegroup.state-graph.transaction-read-scope")
  static let graphImmediateWriterScope: ThreadLocalValue<GraphImmediateWriterScope> = .init(key: "org.vergegroup.state-graph.immediate-writer-scope")

}
