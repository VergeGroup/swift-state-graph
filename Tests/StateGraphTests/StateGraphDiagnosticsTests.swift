import Foundation
import Testing

@testable import StateGraph

#if DEBUG
@Suite("StateGraph Diagnostics Tests", .serialized)
struct StateGraphDiagnosticsTests {

  @Test
  func selfInvalidationWarningIsEmittedOncePerRegistrationAndCanBeDisabled() {
    struct NonEquatableValue: Sendable {
      let rawValue: Int
    }

    let previousValue = StateGraphDiagnostics.isSelfInvalidationWarningEnabled
    defer {
      StateGraphDiagnostics.isSelfInvalidationWarningEnabled = previousValue
    }

    let warningCount = OSAllocatedUnfairLock(initialState: 0)

    Log.$selfInvalidationWarningObserver.withValue({
      warningCount.withLock { $0 += 1 }
    }) {
      StateGraphDiagnostics.isSelfInvalidationWarningEnabled = true

      let firstWarningNode = Stored(
        wrappedValue: NonEquatableValue(rawValue: 0)
      )
      let secondWarningNode = Stored(
        wrappedValue: NonEquatableValue(rawValue: 0)
      )
      let warningCancellable = withGraphTracking {
        withGraphTrackingGroup {
          let firstValue = firstWarningNode.wrappedValue
          let secondValue = secondWarningNode.wrappedValue
          firstWarningNode.wrappedValue = firstValue
          secondWarningNode.wrappedValue = secondValue
        }
      }
      warningCancellable.cancel()

      #expect(warningCount.withLock { $0 } == 1)

      StateGraphDiagnostics.isSelfInvalidationWarningEnabled = false

      let silentNode = Stored(
        wrappedValue: NonEquatableValue(rawValue: 0)
      )
      let silentCancellable = withGraphTracking {
        withGraphTrackingGroup {
          let value = silentNode.wrappedValue
          silentNode.wrappedValue = value
        }
      }
      silentCancellable.cancel()

      #expect(warningCount.withLock { $0 } == 1)
    }
  }
}
#endif
