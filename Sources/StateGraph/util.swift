import Foundation

func withMainActor(_ closure: sending @escaping @MainActor () -> Void) {
  
  if #available(iOS 26, macOS 26, watchOS 26, tvOS 26, *) {
    Task.immediate { @MainActor in
      closure()
    }
  } else {    
    if Thread.isMainThread {
      MainActor.assumeIsolated {
        closure()
      }
    } else {
      Task { @MainActor in
        closure()
      }
    }
  }
  
}
