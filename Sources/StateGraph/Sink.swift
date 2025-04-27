
struct Sink: ~Copyable {
  
  enum Target {
    case handler(() -> Void)
    case stream(AsyncStream<Void>.Continuation)
  }
  
  private var targets: [Target]?
  
  func send() {
    guard let targets else { return }
    for target in targets {
      switch target {
      case .handler(let handler):
        handler()
      case .stream(let continuation):
        continuation.yield(())
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
  
  mutating func addHandler(_ handler: @escaping () -> Void) {
    if targets == nil {
      targets = []
    }
    targets!.append(.handler(handler))
  }
  
  mutating func addStream() -> AsyncStream<Void> {
    if targets == nil {
      targets = []
    }
    return AsyncStream { continuation in
      targets!.append(.stream(continuation))
    }    
  }
  
}


