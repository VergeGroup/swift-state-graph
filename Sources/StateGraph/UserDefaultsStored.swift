import Foundation

// MARK: - UserDefaultsStored

/// A protocol for types that can be stored in UserDefaults
public protocol UserDefaultsStorable: Sendable {
  @_spi(Internal)
  static func getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Self) -> Self
  @_spi(Internal)
  func setValue(to userDefaults: UserDefaults, forKey key: String)
}

extension UserDefaultsStorable {
  @_spi(Internal)
  public static func getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Self) -> Self {
    if userDefaults.object(forKey: key) == nil {
      return defaultValue
    }
    return userDefaults.object(forKey: key) as? Self ?? defaultValue
  }
}

extension Bool: UserDefaultsStorable {
  @_spi(Internal)
  public static func getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Bool) -> Bool {
    if userDefaults.object(forKey: key) == nil {
      return defaultValue
    }
    return userDefaults.bool(forKey: key)
  }
  @_spi(Internal)
  public func setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Int: UserDefaultsStorable {
  @_spi(Internal)
  public static func getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Int) -> Int {
    if userDefaults.object(forKey: key) == nil {
      return defaultValue
    }
    return userDefaults.integer(forKey: key)
  }
  @_spi(Internal)
  public func setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Float: UserDefaultsStorable {
  @_spi(Internal)
  public static func getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Float) -> Float {
    if userDefaults.object(forKey: key) == nil {
      return defaultValue
    }
    return userDefaults.float(forKey: key)
  }
  @_spi(Internal)
  public func setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Double: UserDefaultsStorable {
  @_spi(Internal)
  public static func getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Double) -> Double {
    if userDefaults.object(forKey: key) == nil {
      return defaultValue
    }
    return userDefaults.double(forKey: key)
  }
  @_spi(Internal)
  public func setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension String: UserDefaultsStorable {
  @_spi(Internal)
  public static func getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: String) -> String {
    return userDefaults.string(forKey: key) ?? defaultValue
  }
  @_spi(Internal)
  public func setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Data: UserDefaultsStorable {
  @_spi(Internal)
  public static func getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Data) -> Data {
    return userDefaults.data(forKey: key) ?? defaultValue
  }
  @_spi(Internal)
  public func setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

extension Date: UserDefaultsStorable {
  @_spi(Internal)
  public static func getValue(from userDefaults: UserDefaults, forKey key: String, defaultValue: Date) -> Date {
    return userDefaults.object(forKey: key) as? Date ?? defaultValue
  }
  @_spi(Internal)
  public func setValue(to userDefaults: UserDefaults, forKey key: String) {
    userDefaults.set(self, forKey: key)
  }
}

//extension Array: UserDefaultsStorable where Element: UserDefaultsStorable {
//  public func setValue(to userDefaults: UserDefaults, forKey key: String) {
//    userDefaults.set(self, forKey: key)
//  }
//}
//
//extension Dictionary: UserDefaultsStorable where Key == String, Value: UserDefaultsStorable {
//  public func setValue(to userDefaults: UserDefaults, forKey key: String) {
//    userDefaults.set(self, forKey: key)
//  }
//}

/// A node that functions as an endpoint in a Directed Acyclic Graph (DAG) and persists its value to UserDefaults.
///
/// `UserDefaultsStored` can have its value set directly from the outside, and changes to its value
/// automatically propagate to dependent nodes. The value is automatically persisted to UserDefaults
/// and restored when the node is recreated.
///
/// - When value changes: Changes propagate to all dependent nodes and are persisted to UserDefaults
/// - When value is accessed: Dependencies are recorded and the value is loaded from UserDefaults if needed
public final class UserDefaultsStored<Value: UserDefaultsStorable>: Node, Observable, CustomDebugStringConvertible {
  
  public let lock: NodeLock
  
  nonisolated(unsafe)
  private let userDefaults: UserDefaults
  private let key: String
  private let defaultValue: Value
  
#if canImport(Observation)
  @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
  private var observationRegistrar: ObservationRegistrar {
    _observationRegistrar as! ObservationRegistrar
  }
  private let _observationRegistrar: (Any & Sendable)?
#endif
  
  public var potentiallyDirty: Bool {
    get {
      return false
    }
    set {
      fatalError()
    }
  }
  
  public let info: NodeInfo
  
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
      if let currentNode = TaskLocals.currentNode {
        let edge = Edge(from: self, to: currentNode)
        outgoingEdges.append(edge)
        currentNode.incomingEdges.append(edge)
      }
      // record tracking
      if let registration = TrackingRegistration.registration {
        self.trackingRegistrations.insert(registration)
      }
      
      let value = Value.getValue(from: userDefaults, forKey: key, defaultValue: defaultValue)
      yield value
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
      
      var value = Value.getValue(from: userDefaults, forKey: key, defaultValue: defaultValue)
      yield &value
      
      // Save to UserDefaults
      value.setValue(to: userDefaults, forKey: key)
      
      let _outgoingEdges = outgoingEdges
      let _trackingRegistrations = trackingRegistrations
      self.trackingRegistrations.removeAll()
      
      lock.unlock()
      
      for registration in _trackingRegistrations {
        registration.perform()
      }
      
      for edge in _outgoingEdges {
        edge.isPending = true
        edge.to.potentiallyDirty = true
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
  
  /// Initializes a UserDefaultsStored node with standard UserDefaults.
  ///
  /// - Parameters:
  ///   - file: The file where the node is created (defaults to current file)
  ///   - line: The line number where the node is created (defaults to current line)
  ///   - column: The column number where the node is created (defaults to current column)
  ///   - group: The group name of the node (defaults to nil)
  ///   - name: The name of the node (defaults to nil)
  ///   - key: The UserDefaults key to store the value
  ///   - defaultValue: The default value if no value exists in UserDefaults
  public init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    group: String? = nil,
    name: String? = nil,
    key: String,
    defaultValue: Value
  ) {
    self.info = .init(
      type: Value.self,
      group: group,
      name: name,
      id: makeUniqueNumber(),
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.lock = sharedLock
    self.userDefaults = .standard
    self.key = key
    self.defaultValue = defaultValue
    
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
  
  /// Initializes a UserDefaultsStored node with a specific UserDefaults suite.
  ///
  /// - Parameters:
  ///   - file: The file where the node is created (defaults to current file)
  ///   - line: The line number where the node is created (defaults to current line)
  ///   - column: The column number where the node is created (defaults to current column)
  ///   - group: The group name of the node (defaults to nil)
  ///   - name: The name of the node (defaults to nil)
  ///   - suite: The UserDefaults suite name
  ///   - key: The UserDefaults key to store the value
  ///   - defaultValue: The default value if no value exists in UserDefaults
  public init(
    _ file: StaticString = #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column,
    group: String? = nil,
    name: String? = nil,
    suite: String,
    key: String,
    defaultValue: Value
  ) {
    self.info = .init(
      type: Value.self,
      group: group,
      name: name,
      id: makeUniqueNumber(),
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.lock = sharedLock
    self.userDefaults = UserDefaults(suiteName: suite) ?? .standard
    self.key = key
    self.defaultValue = defaultValue
    
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
    Log.generic.debug("Deinit UserDefaultsStored: \(self.info.name ?? "noname")")
    for edge in outgoingEdges {
      edge.to.incomingEdges.removeAll(where: { $0 === edge })
    }
    outgoingEdges.removeAll()
  }
  
  public func recomputeIfNeeded() {
    // no operation
  }
  
  public var debugDescription: String {
    let value = Value.getValue(from: userDefaults, forKey: key, defaultValue: defaultValue)
    return "UserDefaultsStored<\(Value.self)>(id=\(info.id), name=\(info.name ?? "noname"), key=\(key), value=\(String(describing: value)))"
  }
  
  /// Accesses the value with thread-safe locking.
  ///
  /// - Parameter body: A closure that takes an inout parameter of the value
  /// - Returns: The result of the closure
  borrowing public func withLock<Result, E>(
    _ body: (inout sending Value) throws(E) -> sending Result
  ) throws(E) -> sending Result where E : Error, Result : ~Copyable {
    lock.lock()
    defer {
      lock.unlock()
    }
    var value = Value.getValue(from: userDefaults, forKey: key, defaultValue: defaultValue)
    let result = try body(&value)
    value.setValue(to: userDefaults, forKey: key)
    return result
  }
}
