import Testing
@preconcurrency import StateGraph
import Foundation

@Suite("Actor Isolation Tests")
struct ActorIsolationTests {
  
  final class ThreadTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _callsOnMainActor: Int = 0
    private var _callsOnBackground: Int = 0
    
    var callsOnMainActor: Int {
      lock.lock()
      defer { lock.unlock() }
      return _callsOnMainActor
    }
    
    var callsOnBackground: Int {
      lock.lock()
      defer { lock.unlock() }
      return _callsOnBackground
    }
    
    func recordCall() {
      lock.lock()
      defer { lock.unlock() }
      
      if Thread.isMainThread {
        _callsOnMainActor += 1
      } else {
        _callsOnBackground += 1
      }
    }
    
    func reset() {
      lock.lock()
      defer { lock.unlock() }
      _callsOnMainActor = 0
      _callsOnBackground = 0
    }
  }
  
  @Test @MainActor
  func withGraphTrackingGroupPreservesMainActorIsolation() async throws {
    let node = Stored(wrappedValue: 0)
    let tracker = ThreadTracker()
    
    // Start withGraphTrackingGroup on MainActor
    let cancellable = withGraphTracking {
      withGraphTrackingGroup {
        tracker.recordCall()
        print("=== withGraphTrackingGroup called, value: \(node.wrappedValue), isMainThread: \(Thread.isMainThread) ===")
        _ = node.wrappedValue // Track the node
      }
    }
    
    // Initial call should be on MainActor
    #expect(tracker.callsOnMainActor == 1)
    #expect(tracker.callsOnBackground == 0)
    
    // Update from background thread
    await Task.detached {
      node.wrappedValue = 1
    }.value
    
    try await Task.sleep(nanoseconds: 200_000_000)
    
    // The handler should still be called on MainActor even though update came from background
    #expect(tracker.callsOnMainActor == 2)
    #expect(tracker.callsOnBackground == 0)
    
    cancellable.cancel()
  }
  
  @Test @MainActor
  func onChangePreservesMainActorIsolation() async throws {
    let node = Stored(wrappedValue: 0)
    let tracker = ThreadTracker()

    // Start onChange on MainActor
    let cancellable = withGraphTracking {
      withGraphTrackingMap {
        node.wrappedValue
      } onChange: { value in
        tracker.recordCall()
        print("=== onChange called, value: \(value), isMainThread: \(Thread.isMainThread) ===")
      }
    }
    
    try await Task.sleep(nanoseconds: 100_000_000)
    
    // Initial call should be on MainActor
    #expect(tracker.callsOnMainActor == 1)
    #expect(tracker.callsOnBackground == 0)
    
    // Update from background thread
    await Task.detached {
      node.wrappedValue = 1
    }.value
    
    try await Task.sleep(nanoseconds: 200_000_000)
    
    // The onChange callback should still be called on MainActor
    #expect(tracker.callsOnMainActor == 2)
    #expect(tracker.callsOnBackground == 0)
    
    cancellable.cancel()
  }
}