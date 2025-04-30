import os.lock

public protocol StateViewType {

}

open class StateView: Hashable, StateViewType {

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }

  public static func == (lhs: StateView, rhs: StateView) -> Bool {
    return lhs === rhs
  }

  public init() {
  }

  private let lock: OSAllocatedUnfairLock<Void> = .init()
  nonisolated(unsafe)
    private var _sink: Sink = .init()

  public func onChange() -> AsyncStream<Void> {
    lock.lock()
    defer {
      lock.unlock()
    }
    return _sink.addStream()
  }

  func _onMemberChange() {

    onMemberChange()

    lock.lock()
    defer {
      lock.unlock()
    }
    _sink.send()

  }

  open func onMemberChange() {

  }

}

extension StateViewType where Self: StateView {

  public typealias Computed<Value> = ComputedMember<Value>
  public typealias Stored<Value> = StoredMember<Value>

}

#if canImport(SwiftUI)

  import SwiftUI

  extension SwiftUI.View {

    public typealias Computed = SwiftUI_Computed
    public typealias Stored = SwiftUI_Stored
  }

  @propertyWrapper
  public struct SwiftUI_Computed<Value>: DynamicProperty {

    public var wrappedValue: Value {
      node.wrappedValue.wrappedValue
    }

    private let node: ObjectEdge<ComputedNode<Value>>

    public init(compute: @escaping @Sendable () -> Value) {
      self.node = .init(wrappedValue: .init(rule: compute))
    }

  }

  @propertyWrapper
  public struct SwiftUI_Stored<Value>: DynamicProperty {

    public var wrappedValue: Value {
      get { node.wrappedValue.wrappedValue }
      nonmutating set { node.wrappedValue.wrappedValue = newValue }
    }

    private let node: ObjectEdge<StoredNode<Value>>

    public init(wrappedValue initialValue: Value) {
      self.node = .init(wrappedValue: .init(wrappedValue: initialValue))
    }

  }

  // TODO: replace with original
  @propertyWrapper
  private struct ObjectEdge<O>: DynamicProperty {

    @State private var box: Box<O> = .init()

    public var wrappedValue: O {
      if let value = box.value {
        return value
      } else {
        box.value = factory()
        return box.value!
      }
    }

    private let factory: () -> O

    public init(wrappedValue factory: @escaping @autoclosure () -> O) {
      self.factory = factory
    }

    private final class Box<Value> {
      var value: Value?
    }

  }

#endif
