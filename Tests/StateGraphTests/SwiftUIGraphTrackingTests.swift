#if canImport(SwiftUI)

import SwiftUI
import Testing

@testable import StateGraph

@Suite("SwiftUI GraphTracking Tests")
struct SwiftUIGraphTrackingTests {

  @Test
  @MainActor
  func graphTrackingModifierBuildsView() {
    let model = GraphTrackingModifierModel()

    let view = Text("Count")
      .graphTracking {
        withGraphTrackingGroup {
          _ = model.count
        }
      }

    _ = view
  }

  @Test
  @MainActor
  func graphTrackingIDModifierBuildsView() {
    let model = GraphTrackingModifierModel()

    let view = Text("Count")
      .graphTracking(id: ObjectIdentifier(model)) {
        withGraphTrackingMap {
          model.count
        } onChange: { _ in
        }
      }

    _ = view
  }
}

private final class GraphTrackingModifierModel {

  @GraphStored var count: Int = 0
}

#endif
