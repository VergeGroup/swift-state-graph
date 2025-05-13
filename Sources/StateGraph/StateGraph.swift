import Foundation.NSLock

#if canImport(Observation)
  import Observation
#endif

/**
 based on
 https://talk.objc.io/episodes/S01E429-attribute-graph-part-1
 */

private enum TaskLocals {
  @TaskLocal
  static var currentNode: (any TypeErasedNode)?
}


/// A node that functions as an endpoint in a Directed Acyclic Graph (DAG).
///
/// `StoredNode` can have its value set directly from the outside, and changes to its value
/// automatically propagate to dependent nodes. This node doesn't perform any computations
/// and serves purely as a value container.
///
/// - When value changes: Changes propagate to all dependent nodes, triggering recalculations
/// - When value is accessed: Dependencies are recorded, automatically building the graph structure
public final class Stored<Value>: Node, Observable, CustomDebugStringConvertible {

  public let lock: NodeLock

  nonisolated(unsafe)
    private var _value: Value

  #if canImport(Observation)
    nonisolated(unsafe)
  private var observationRegistrar: ObservationRegistrar = .init()
  #endif

  public var potentiallyDirty: Bool {
    get {
      return false
    }
    set {
      fatalError()
    }
  }

  public let name: String?
  public let info: NodeInfo

  public var wrappedValue: Value {
    _read {
      
#if canImport(Observation)
      observationRegistrar.access(self, keyPath: \.self)
#endif
      
      lock.lock()
      defer { lock.unlock() }
                
      // record dependency
      if let c = TaskLocals.currentNode {
        let edge = Edge(from: self, to: c)
        outgoingEdges.append(edge)
        c.incomingEdges.append(edge)
      }
      // record tracking
      if let registration = TrackingRegistration.registration {
        self.trackingRegistrations.insert(registration)
      }
      yield _value
    }
    _modify {

#if canImport(Observation)
      observationRegistrar.willSet(self, keyPath: \.self)
      
      defer {
        observationRegistrar.didSet(self, keyPath: \.self)
      }
#endif
      
      lock.lock()

      yield &_value
          
      let _outgoingEdges = outgoingEdges
      let _trackingRegistrations = trackingRegistrations
      self.trackingRegistrations.removeAll()
                           
      lock.unlock()
      
      for r in _trackingRegistrations {
        r.perform()
      }
      
      for e in _outgoingEdges {
        e.isPending = true
        e.to.potentiallyDirty = true
      }
    }
  }

  public var incomingEdges: ContiguousArray<Edge> {
    get {
      fatalError()
    }
    set {
      fatalError()
    }
  }

  nonisolated(unsafe)
  public var outgoingEdges: ContiguousArray<Edge> = []
  
  nonisolated(unsafe)
  public var trackingRegistrations: Set<TrackingRegistration> = []

  public init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: String? = nil,
    wrappedValue: Value
  ) {
    self.info = .init(
      id: makeUniqueNumber(),
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.name = name
    self.lock = sharedLock
    self._value = wrappedValue
    
    #if DEBUG
    Task {
      await NodeStore.shared.register(node: self)
    }
    #endif
  }

  deinit {
    Log.generic.debug("Deinit Stored: \(self.name ?? "noname")")
    for e in outgoingEdges {
      e.to.incomingEdges.removeAll(where: { $0 === e })
    }
  }

  public func recomputeIfNeeded() {
    // no operation
  }

  public var debugDescription: String {
    "Stored<\(Value.self)>(\(String(describing: _value)))"
  }
}

public protocol ComputedDescriptor<Value>: Sendable {
  
  associatedtype Value
  
  func compute(context: inout Computed<Value>.Context) -> Value
  
  func isEqual(lhs: Value, rhs: Value) -> Bool
}

extension ComputedDescriptor {
  
  @Sendable
  public static func any<Value>(
    _ compute: @Sendable @escaping (inout Computed<Value>.Context) -> Value
  ) -> Self where Self == AnyComputedDescriptor<Value> {
    AnyComputedDescriptor(compute: compute, isEqual: { _, _ in false })
  }
  
  @Sendable
  public static func any<Value>(
    _ compute: @Sendable @escaping (
      inout Computed<Value>.Context
    ) -> Value
  ) -> Self where Self == AnyComputedDescriptor<Value>, Value: Equatable {
    AnyComputedDescriptor(compute: compute)
  }
  
}

public struct AnyComputedDescriptor<Value>: ComputedDescriptor {

  private let computeClosure: @Sendable (inout Computed<Value>.Context) -> Value
  private let isEqualClosure: @Sendable (Value, Value) -> Bool
  
  public init(
    compute: @escaping @Sendable (inout Computed<Value>.Context) -> Value,
    isEqual: @escaping @Sendable (Value, Value) -> Bool
  ) {
    self.computeClosure = compute  
    self.isEqualClosure = isEqual
  }
  
  public init(
    compute: @escaping @Sendable (inout Computed<Value>.Context) -> Value
  ) where Value : Equatable {
    self.computeClosure = compute  
    self.isEqualClosure = { $0 == $1 }
  }
      
  public func compute(context: inout Computed<Value>.Context) -> Value {
    computeClosure(&context)
  }
  
  public func isEqual(lhs: Value, rhs: Value) -> Bool {
    isEqualClosure(lhs, rhs)
  }
      
}

public protocol ComputedEnvironmentKey {
  associatedtype Value
}

public struct ComputedEnvironmentValues {
  
  struct AnyMetatypeWrapper: Hashable {
    let metatype: Any.Type
    
    static func ==(lhs: Self, rhs: Self) -> Bool {
      lhs.metatype == rhs.metatype
    }
    
    func hash(into hasher: inout Hasher) {
      hasher.combine(ObjectIdentifier(metatype))
    }    
  }
  
  private var values: [AnyMetatypeWrapper: Any] = [:]
  
  public subscript<K: ComputedEnvironmentKey>(key: K.Type) -> K.Value? {
    get {
      return values[.init(metatype: key)] as? K.Value
    }
    set {
      values[.init(metatype: key)] = newValue      
    }
  }
}

public enum StateGraphGlobal {
  
  public static let computedEnvironmentValues: OSAllocatedUnfairLock<ComputedEnvironmentValues> = .init(
    uncheckedState: .init()
  )
  
}
  
/// A node that computes its value based on other nodes in a Directed Acyclic Graph (DAG).
///
/// `Computed` derives its value from other nodes through a computation rule.
/// When any of its dependencies change, the node becomes dirty and will recalculate
/// its value on the next access. This node caches its computed value for performance.
///
/// - Value is lazily computed: Calculations only occur when the value is accessed
/// - Dependencies are tracked: The node automatically tracks which nodes it depends on
/// - Changes propagate: When this node's value changes, downstream nodes are notified
/// ```
public final class Computed<Value>: Node, Observable, CustomDebugStringConvertible {
    
  public struct Context {
    
    @dynamicMemberLookup
    public struct Environment {
      
      public subscript<T: ComputedEnvironmentKey>(
        dynamicMember keyPath: KeyPath<ComputedEnvironmentValues, T>
      ) -> T {
        StateGraphGlobal.computedEnvironmentValues.withLockUnchecked {
          $0[keyPath: keyPath]
        }
      }

    }
    
    public let environment: Environment
    
  }
    
  public let lock: NodeLock

  nonisolated(unsafe)
    private var _cachedValue: Value?
  
  #if canImport(Observation)
    nonisolated(unsafe)
  private var observationRegistrar: ObservationRegistrar = .init()
  #endif

  public var potentiallyDirty: Bool {
    get {
      lock.lock()
      defer {
        lock.unlock()
      }
      return _potentiallyDirty
    }
    set {
      lock.lock()
          
      let oldValue = _potentiallyDirty
      _potentiallyDirty = newValue
      
      guard _potentiallyDirty, _potentiallyDirty != oldValue else {
        lock.unlock()
        return 
      }
      
#if canImport(Observation)
      observationRegistrar.willSet(self, keyPath: \.self)
#endif
      
      let _outgoingEdges = outgoingEdges
      let _trackingRegistrations = trackingRegistrations
      trackingRegistrations.removeAll()
      
      lock.unlock()
      
      for e in _outgoingEdges {
        e.to.potentiallyDirty = true
      }
      
      for r in _trackingRegistrations {
        r.perform()
      }
            
    }
  }

  nonisolated(unsafe)
  private var _potentiallyDirty: Bool = false

  public let name: String?
  public let info: NodeInfo

  public var wrappedValue: Value {
    _read {
      #if canImport(Observation)
        observationRegistrar.access(self, keyPath: \.self)
      #endif
      recomputeIfNeeded()
      yield _cachedValue!
    }
  }

  private let descriptor: any ComputedDescriptor<Value>

  nonisolated(unsafe)
  public var incomingEdges: ContiguousArray<Edge> = []
  
  nonisolated(unsafe)
  public var outgoingEdges: ContiguousArray<Edge> = []
  
  nonisolated(unsafe)
  public var trackingRegistrations: Set<TrackingRegistration> = []

  /// Initializes a computed node.
  ///
  /// This initializer uses a comparison function that always returns `false`.
  /// This means updates will always occur regardless of whether the value has changed.
  ///
  /// - Parameters:
  ///   - file: The file where the node is created (defaults to current file)
  ///   - line: The line number where the node is created (defaults to current line)
  ///   - column: The column number where the node is created (defaults to current column)
  ///   - name: Optional name for the node
  ///   - rule: The rule that computes the node's value
  public init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: String? = nil,
    descriptor: some ComputedDescriptor<Value>
  ) {
    self.info = .init(
      id: makeUniqueNumber(),
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.name = name
    self.descriptor = descriptor
    self.lock = .init()
    
#if DEBUG
    Task {
      await NodeStore.shared.register(node: self)
    }
#endif
  }
  
  /// Initializes a computed node.
  ///
  /// This initializer uses a comparison function that always returns `false`.
  /// This means updates will always occur regardless of whether the value has changed.
  ///
  /// - Parameters:
  ///   - file: The file where the node is created (defaults to current file)
  ///   - line: The line number where the node is created (defaults to current line)
  ///   - column: The column number where the node is created (defaults to current column)
  ///   - name: Optional name for the node
  ///   - rule: The rule that computes the node's value
  public init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: String? = nil,
    rule: @escaping @Sendable (inout Context) -> Value
  ) {
    self.info = .init(
      id: makeUniqueNumber(),
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.name = name
    self.descriptor = AnyComputedDescriptor(compute: rule, isEqual: { _, _ in false })      
    self.lock = .init()
    
#if DEBUG
    Task {
      await NodeStore.shared.register(node: self)
    }
#endif
  }

  /// Initializes a computed node.
  ///
  /// This initializer uses a comparison function that always returns `false`.
  /// This means updates will always occur regardless of whether the value has changed.
  ///
  /// - Parameters:
  ///   - file: The file where the node is created (defaults to current file)
  ///   - line: The line number where the node is created (defaults to current line)
  ///   - column: The column number where the node is created (defaults to current column)
  ///   - name: Optional name for the node
  ///   - rule: The rule that computes the node's value
  public init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: String? = nil,
    rule: @escaping @Sendable (inout Context) -> Value
  ) where Value: Equatable {
    self.info = .init(
      id: makeUniqueNumber(),
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.name = name
    self.descriptor = AnyComputedDescriptor(compute: rule, isEqual: { $0 == $1 })
    self.lock = .init()
    
#if DEBUG
    Task {
      await NodeStore.shared.register(node: self)
    }
#endif
  }
  
  deinit {
    Log.generic.debug("Deinit Computed: \(self.name ?? "noname")")
    for e in incomingEdges {
      e.from.outgoingEdges.removeAll(where: { $0 === e })
    }
  }

  public func recomputeIfNeeded() {

    lock.lock()
    defer { lock.unlock() }

    // record dependency
    if let c = TaskLocals.currentNode {
      let edge = Edge(from: self, to: c)
      // TODO: consider removing duplicated edges
      outgoingEdges.append(edge)
      c.incomingEdges.append(edge)
    }
    // record tracking
    if let registration = TrackingRegistration.registration {
      self.trackingRegistrations.insert(registration)
    }

    if !_potentiallyDirty && _cachedValue != nil { return }

    for edge in incomingEdges {
      edge.from.recomputeIfNeeded()
    }

    let hasPendingIncomingEdge = incomingEdges.contains(where: \.isPending)

    if hasPendingIncomingEdge || _cachedValue == nil {

      TaskLocals.$currentNode.withValue(self) { () -> Void in
        let previousValue = _cachedValue
        removeIncomingEdges()
        var context = Context(environment: .init())
        _cachedValue = descriptor.compute(context: &context)

        // propagate changes to dependent nodes
        do {

          if let previousValue = previousValue,
             descriptor.isEqual(lhs: previousValue, rhs: _cachedValue!) == false
          {
            for o in outgoingEdges {
              o.isPending = true
            }
          }

        }
      }

    }

    _potentiallyDirty = false

  }

  private func removeIncomingEdges() {
    for e in incomingEdges {
      e.from.lock.lock()
      e.from.outgoingEdges.removeAll(where: { $0 === e })
      e.from.lock.unlock()
    }
    incomingEdges.removeAll()
  }
   
  public var debugDescription: String {
    "Computed<\(Value.self)>(\(String(describing: _cachedValue)))"
  }
  
}

@DebugDescription
public final class Edge: CustomDebugStringConvertible {

  unowned let from: any TypeErasedNode
  unowned let to: any TypeErasedNode
  
  private let lock: NodeLock = sharedLock
  
  var isPending: Bool {
    _read {
      lock.lock()
      defer { lock.unlock() }
      yield _isPending
    }
    _modify {
      lock.lock()
      defer { lock.unlock() }
      yield &_isPending
    }
  }

  private var _isPending: Bool = false

  init(from: any TypeErasedNode, to: any TypeErasedNode) {
    self.from = from
    self.to = to
  }

  public var debugDescription: String {
    "\(from.debugDescription) -> \(to.name.debugDescription)"
  }

  deinit {
//    Log.generic.debug("Deinit Edge")
  }
  
}

public typealias NodeLock = NSRecursiveLock

let sharedLock: NodeLock = NodeLock()
