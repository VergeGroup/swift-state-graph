
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

  func withValue<R>(_ value: Value?, perform: () throws -> R) rethrows -> R {
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

}

/// Context for tracking which node triggered a change.
/// Uses TaskLocal to propagate the changing node through Task boundaries.
public enum ChangingNodeContext {
  @TaskLocal
  public static var current: (any TypeErasedNode)?
}
