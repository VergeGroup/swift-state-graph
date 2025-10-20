import Foundation

func withMainActor(_ closure: sending @escaping @MainActor () -> Void) {
  
  if #available(iOS 26, macOS 26, watchOS 26, tvOS 26, *) {
    print("enter")
    Task.immediate { @MainActor in
      print("inside")
      closure()
    }
    print("leave")
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
