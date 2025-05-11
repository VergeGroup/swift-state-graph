import os.lock

/**
 Use @GraphView macro
 */
public protocol GraphViewType: Observable, Equatable, Hashable, AnyObject {
  
}

extension GraphViewType {
  
  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
  
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs === rhs
  }
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

    public var projectedValue: SwiftUI_Computed<Value> {
      return .init(node: node.wrappedValue)
    }

    private let node: ObjectEdge<Computed<Value>>

    public init(
      _ file: StaticString = #file,
      _ line: UInt = #line,
      _ column: UInt = #column,
      compute: @escaping @Sendable (inout Computed<Value>.Context) -> Value
    ) {
      self.node = .init(
        wrappedValue: .init(
          file,
          line,
          column,
          rule: compute
        ))
    }

    public init(
      node: Computed<Value>
    ) {
      self.node = .init(wrappedValue: node)
    }

  }

  @propertyWrapper
  public struct SwiftUI_Stored<Value>: DynamicProperty {

    public var wrappedValue: Value {
      get { node.wrappedValue.wrappedValue }
      nonmutating set { node.wrappedValue.wrappedValue = newValue }
    }

    public var projectedValue: SwiftUI_Stored<Value> {
      .init(node: node.wrappedValue)
    }

    private let node: ObjectEdge<Stored<Value>>

    public init(
      _ file: StaticString = #file,
      _ line: UInt = #line,
      _ column: UInt = #column,
      wrappedValue initialValue: Value
    ) {
      self.node = .init(wrappedValue: .init(wrappedValue: initialValue))
    }

    public init(
      _ file: StaticString = #file,
      _ line: UInt = #line,
      _ column: UInt = #column,
      node: Stored<Value>
    ) {
      self.node = .init(wrappedValue: node)
    }

  }

  // TODO: replace with original
  @propertyWrapper
  private struct ObjectEdge<O>: DynamicProperty {

    @State private var box: Box<O> = .init()

    var wrappedValue: O {
      if let value = box.value {
        return value
      } else {
        box.value = factory()
        return box.value!
      }
    }

    private let factory: () -> O

    init(wrappedValue factory: @escaping @autoclosure () -> O) {
      self.factory = factory
    }

    private final class Box<Value> {
      var value: Value?
    }

  }

#endif
