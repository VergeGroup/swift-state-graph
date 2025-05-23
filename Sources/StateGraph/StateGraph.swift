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
/// Node holding a mutable value that can be observed by other nodes.
public final class Stored<Value>: Node, Observable, CustomDebugStringConvertible {

  /// Lock protecting mutations on the node.
  /// Lock protecting cached value and dependency lists.
  public let lock: NodeLock

  nonisolated(unsafe)
    private var _value: Value

  #if canImport(Observation)
  @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
  /// Registrar used for the Observation framework, if available.
  private var observationRegistrar: ObservationRegistrar {
    _observationRegistrar as! ObservationRegistrar
  }
  /// Storage for the registrar allowing ``Stored`` to be ``Observable``.
  private let _observationRegistrar: (Any & Sendable)?
  #endif

  /// Stored nodes are never dirty as they don't compute values.
  public var potentiallyDirty: Bool {
    get {
      return false
    }
    set {
      fatalError()
    }
  }

  /// Information describing this node for debugging.
  public let info: NodeInfo

  /// The contained value.
  public var wrappedValue: Value {
    _read {
      
#if canImport(Observation)
      if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
        observationRegistrar.access(self, keyPath: \.self)
      }
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
      if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) { 
        observationRegistrar.willSet(self, keyPath: \.self)
      }
      
      defer {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
          observationRegistrar.didSet(self, keyPath: \.self)
        }
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

  /// Nodes that depend on this node.
  public var incomingEdges: ContiguousArray<Edge> {
    get {
      fatalError()
    }
    set {
      fatalError()
    }
  }

  nonisolated(unsafe)
  /// Nodes that this node depends on.
  public var outgoingEdges: ContiguousArray<Edge> = []
  
  nonisolated(unsafe)
  /// Tracking registrations attached to this node.
  public var trackingRegistrations: Set<TrackingRegistration> = []

  public init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    group: String? = nil,
    name: String? = nil,
    wrappedValue: Value
  ) {
    self.info = .init(
      type: Value.self,
      group: group,
      name: name,
      id: makeUniqueNumber(),
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.lock = sharedLock
    self._value = wrappedValue

    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
      self._observationRegistrar = ObservationRegistrar()
    } else {
      self._observationRegistrar = nil
    }

    #if DEBUG
    Task {
      await NodeStore.shared.register(node: self)
    }
    #endif
  }

  deinit {
    Log.generic.debug("Deinit Stored: \(self.info.name ?? "noname")")
    for e in outgoingEdges {
      e.to.incomingEdges.removeAll(where: { $0 === e })
    }
    outgoingEdges.removeAll()
  }

  public func recomputeIfNeeded() {
    // no operation
  }

  public var debugDescription: String {
    "Stored<\(Value.self)>(id=\(info.id), name=\(info.name ?? "noname"), value=\(String(describing: _value)))"
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
    
    /**
     Use this method to perform actions without tracking dependencies.
     
     This case does not track `isRemoved` property.
     ```swift
     Computed { context in 
       node.filter { 
         context.withoutTracking {
           $0.isRemoved == true
         }
       }
     }
     ```
     */
    public func withoutTracking<R>(_ block: () throws -> R) rethrows -> R{
      try TaskLocals.$currentNode.withValue(nil) {
        try block()
      }
    }
    
    public let environment: Environment
    
  }
    
  public let lock: NodeLock

  nonisolated(unsafe)
    /// Cached result of the computation.
    private var _cachedValue: Value?
  
  #if canImport(Observation)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    /// Registrar used for Observation support, if available.
    private var observationRegistrar: ObservationRegistrar {
      _observationRegistrar as! ObservationRegistrar
    }
    /// Storage for Observation registrar.
    private let _observationRegistrar: (Any & Sendable)?
  #endif

  /// Indicates whether the cached value may be outdated.
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
      if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
        observationRegistrar.willSet(self, keyPath: \.self)
      }
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

  /// Information describing this node for debugging.
  public let info: NodeInfo

  /// Accesses the computed value, recomputing if needed.
  public var wrappedValue: Value {
    _read {
      #if canImport(Observation)
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
          observationRegistrar.access(self, keyPath: \.self)
        }
      #endif
      recomputeIfNeeded()
      yield _cachedValue!
    }
  }

  /// Descriptor used to compute the value and compare equality.
  private let descriptor: any ComputedDescriptor<Value>

  nonisolated(unsafe)
  /// Nodes this computed node depends on.
  public var incomingEdges: ContiguousArray<Edge> = []
  
  nonisolated(unsafe)
  /// Nodes that depend on this computed node.
  public var outgoingEdges: ContiguousArray<Edge> = []
  
  nonisolated(unsafe)
  /// Registrations to notify when the value changes.
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
  ///   - name: The name of the node (defaults to nil)
  ///   - rule: The rule that computes the node's value
  public init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: String? = nil,
    descriptor: some ComputedDescriptor<Value>
  ) {
    self.info = .init(
      type: Value.self,
      group: nil,
      name: name,
      id: makeUniqueNumber(),
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.descriptor = descriptor
    self.lock = .init()

    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
      self._observationRegistrar = ObservationRegistrar()
    } else {
      self._observationRegistrar = nil
    }

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
  ///   - name: The name of the node (defaults to nil)
  ///   - rule: The rule that computes the node's value
  public init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: String? = nil,
    rule: @escaping @Sendable (inout Context) -> Value
  ) {
    self.info = .init(
      type: Value.self,
      group: nil,
      name: name,
      id: makeUniqueNumber(),
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.descriptor = AnyComputedDescriptor(compute: rule, isEqual: { _, _ in false })      
    self.lock = sharedLock

    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
      self._observationRegistrar = ObservationRegistrar()
    } else {
      self._observationRegistrar = nil
    }

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
  ///   - name: The name of the node (defaults to nil)
  ///   - rule: The rule that computes the node's value
  public init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    name: String? = nil,
    rule: @escaping @Sendable (inout Context) -> Value
  ) where Value: Equatable {
    self.info = .init(
      type: Value.self,
      group: nil,
      name: name,
      id: makeUniqueNumber(),
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.descriptor = AnyComputedDescriptor(compute: rule, isEqual: { $0 == $1 })
    self.lock = sharedLock

    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
      self._observationRegistrar = ObservationRegistrar()
    } else {
      self._observationRegistrar = nil
    }

#if DEBUG
    Task {
      await NodeStore.shared.register(node: self)
    }
#endif
  }
  
  deinit {
    Log.generic.debug("Deinit Computed: id=\(self.info.id)")
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

        /**
        To prevent adding tracking registration to the incoming nodes.
        Only register the registration to the current node.
        */        
        _cachedValue = TrackingRegistration.$registration.withValue(nil) {
          return descriptor.compute(context: &context)
        }

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
    "Computed<\(Value.self)>(id=\(info.id), name=\(info.name ?? "noname"), value=\(String(describing: _cachedValue)))"
  }
  
}

@DebugDescription
/// Represents a dependency from one node to another.
public final class Edge: CustomDebugStringConvertible {

  /// Node from which the edge originates.
  unowned let from: any TypeErasedNode
  /// Node the edge points to.
  unowned let to: any TypeErasedNode
  
  /// Synchronization lock for pending state.
  private let lock: NodeLock = sharedLock
  
  /// Indicates whether the edge is waiting to propagate changes.
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

  /// Creates an edge connecting ``from`` to ``to``.
  init(from: any TypeErasedNode, to: any TypeErasedNode) {
    self.from = from
    self.to = to
  }

  public var debugDescription: String {
    "\(from.debugDescription) -> \(to.debugDescription)"
  }

  deinit {
//    Log.generic.debug("Deinit Edge")
  }
  
}

/// Lock type used throughout the state graph.
public typealias NodeLock = NSRecursiveLock

/// Global lock instance used by nodes.
let sharedLock: NodeLock = NodeLock()
