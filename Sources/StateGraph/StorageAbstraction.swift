import Foundation

#if canImport(Observation)
  import Observation
#endif

// MARK: - Base Stored Node

public final class _Stored<Value, S: Storage<Value>>: Node, Observable, CustomDebugStringConvertible {
  
  public let lock: NodeLock
  
  nonisolated(unsafe)
  private var storage: S
  
#if canImport(Observation)
  @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
  private var observationRegistrar: ObservationRegistrar {
    return .shared
  }
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
  
  public var wrappedValue: S.Value {
    get {
      
#if canImport(Observation)
      if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
        observationRegistrar.access(PointerKeyPathRoot.shared, keyPath: _keyPath(self))        
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
      
      return storage.value
    }
    set {
      
#if canImport(Observation)
      if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) { 
        observationRegistrar.willSet(PointerKeyPathRoot.shared, keyPath: _keyPath(self))   
      }
      
      defer {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
          observationRegistrar.didSet(PointerKeyPathRoot.shared, keyPath: _keyPath(self))
        }
      }
#endif
      
      lock.lock()
      
      storage.value = newValue
      
      let _outgoingEdges = outgoingEdges
      let _trackingRegistrations = trackingRegistrations
      self.trackingRegistrations.removeAll()
      
      lock.unlock()
      
      for registration in _trackingRegistrations {
        registration.perform(context: .init(nodeInfo: info))
      }
      
      for edge in _outgoingEdges {
        edge.isPending = true
        edge.to.potentiallyDirty = true
      }
    }
  }
  
  private func notifyStorageUpdated() {
#if canImport(Observation)
    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
      // Workaround: SwiftUI will not trigger update if we call only didSet.
      // as here is where the value already updated.
      observationRegistrar.willSet(PointerKeyPathRoot.shared, keyPath: _keyPath(self))   
      observationRegistrar.didSet(PointerKeyPathRoot.shared, keyPath: _keyPath(self))   
    }
#endif
    
    lock.lock()
        
    let _outgoingEdges = outgoingEdges
    let _trackingRegistrations = trackingRegistrations
    self.trackingRegistrations.removeAll()
    
    lock.unlock()
    
    for registration in _trackingRegistrations {
      registration.perform(context: .init(nodeInfo: info))
    }
    
    for edge in _outgoingEdges {
      edge.isPending = true
      edge.to.potentiallyDirty = true
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
    name: StaticString? = nil,
    storage: consuming S
  ) {
    self.info = .init(
      name: name,
      sourceLocation: .init(file: file, line: line, column: column)
    )
    self.lock = .init()
    self.storage = storage
           
    self.storage.loaded(context: .init(onStorageUpdated: { [weak self] in      
      self?.notifyStorageUpdated()      
    }))
    
#if DEBUG
    Task {
      await NodeStore.shared.register(node: self)
    }
#endif
  }
  
  deinit {
//    Log.generic.debug("Deinit StoredNode: \(self.info.name.map(String.init) ?? "noname")")
    for edge in outgoingEdges {
      edge.to.incomingEdges.removeAll(where: { $0 === edge })
    }
    outgoingEdges.removeAll()
    storage.unloaded()
  }
  
  public func recomputeIfNeeded() {
    // no operation
  }
  
  public var debugDescription: String {
    let value = storage.value
    let typeName = _typeName(type(of: self))    
    return "\(typeName)(name=\(info.name.map(String.init) ?? "noname"), value=\(String(describing: value)))"
  }
  
  /// Accesses the value with thread-safe locking.
  ///
  /// - Parameter body: A closure that takes an inout parameter of the value
  /// - Returns: The result of the closure
  public borrowing func withLock<Result, E>(
    _ body: (inout S.Value) throws(E) -> Result
  ) throws(E) -> Result where E : Error {
    lock.lock()
    defer {
      lock.unlock()
    }
    let result = try body(&storage.value)
    return result
  }
  
} 
