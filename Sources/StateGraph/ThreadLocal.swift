
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

  func withValue<R, Failure: Error>(_ value: Value?, perform: () throws(Failure) -> R) throws(Failure) -> R {
    let oldValue = Thread.current.threadDictionary[key]
    if let value {
      Thread.current.threadDictionary[key] = value
    } else {
      Thread.current.threadDictionary.removeObject(forKey: key)
    }
    defer {
      if let oldValue {
        Thread.current.threadDictionary[key] = oldValue
      } else {
        Thread.current.threadDictionary.removeObject(forKey: key)
      }
    }
    return try perform()
  }

}

enum ThreadLocal: Sendable {

  static let registration: ThreadLocalValue<TrackingRegistration> = .init(key: "org.vergegroup.state-graph.registration")
  static let subscriptions: ThreadLocalValue<Subscriptions> = .init(key: "org.vergegroup.state-graph.subscriptions")
  static let currentNode: ThreadLocalValue<any TypeErasedNode> = .init(key: "org.vergegroup.state-graph.currentNode")
  static let currentCancellable: ThreadLocalValue<GraphTrackingCancellable> = .init(key: "org.vergegroup.state-graph.currentCancellable")
  /// The collecting transaction whose staged values are visible to getters.
  static let transaction: ThreadLocalValue<GraphTransaction> = .init(
    key: "org.vergegroup.state-graph.transaction"
  )

  /// The transaction currently applying and publishing a committed batch.
  ///
  /// This is separate from `transaction` so a commit callback can install a child
  /// read/write overlay without hiding the parent commit phase from storage callbacks.
  static let committingTransaction: ThreadLocalValue<GraphTransaction> = .init(
    key: "org.vergegroup.state-graph.committingTransaction"
  )

  /// The FIFO commit wave shared by a root transaction and its follow-up batches.
  static let transactionCommitQueue: ThreadLocalValue<GraphTransactionCommitQueue> = .init(
    key: "org.vergegroup.state-graph.transactionCommitQueue"
  )
}
