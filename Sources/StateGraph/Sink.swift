import os.lock

public final class Sink<Output>: Sendable {
  
  enum Target {
    case handler(@Sendable (Output) -> Void)
    case stream(AsyncStream<Output>.Continuation)
  }
  
  private let lock: OSAllocatedUnfairLock<Void> = .init()
  
  nonisolated(unsafe)
  private var targets: ContiguousArray<Target>?
  
  func send(output: sending Output) {
    let targets: ContiguousArray<Target>?
    lock.lock()
    targets = self.targets
    lock.unlock()
    guard let targets else { return }
    for target in targets {
      switch target {
      case .handler(let handler):
        handler(output)
      case .stream(let continuation):
        let workaround = { output }
        let output = workaround()
        continuation.yield(output)
      }
    }
  }
  
  deinit {
    guard let targets else { return }
    for target in targets {
      switch target {
      case .handler:
        break
      case .stream(let continuation):
        continuation.finish()
      }
    }
  }
  
  public func addHandler(_ handler: @escaping @Sendable (Output) -> Void) {
    lock.lock()
    defer {
      lock.unlock()
    }
    if targets == nil {
      targets = []
    }
    targets!.append(.handler(handler))
  }
  
  public func addStream() -> AsyncStream<Output> {
    lock.lock()
    defer {
      lock.unlock()
    }
    if targets == nil {
      targets = []
    }
    let (stream, continuation) = AsyncStream.makeStream(of: Output.self)
    targets!.append(.stream(continuation))
    return stream
  }
  
}

struct _Sink<Output>: ~Copyable {
  
  enum Target {
    case handler(@Sendable (Output) -> Void)
    case stream(AsyncStream<Output>.Continuation)
  }
    
  private var targets: ContiguousArray<Target>?
  
  func send(output: sending Output) {
    guard let targets else { return }
    for target in targets {
      switch target {
      case .handler(let handler):
        handler(output)
      case .stream(let continuation):
        let workaround = { output }
        let output = workaround()
        continuation.yield(output)
      }
    }
  }
  
  deinit {
    guard let targets else { return }
    for target in targets {
      switch target {
      case .handler:
        break
      case .stream(let continuation):
        continuation.finish()
      }
    }
  }
  
  public mutating func addHandler(_ handler: @escaping @Sendable (Output) -> Void) {
    if targets == nil {
      targets = []
    }
    targets!.append(.handler(handler))
  }
  
  public mutating func addStream() -> AsyncStream<Output> { 
    if targets == nil {
      targets = []
    }
    let (stream, continuation) = AsyncStream.makeStream(of: Output.self)
    targets!.append(.stream(continuation))
    return stream
  }
  
}
