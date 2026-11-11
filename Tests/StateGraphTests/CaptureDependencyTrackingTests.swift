import Testing

@testable import StateGraph

@Suite
struct CaptureDependencyTrackingTests {

  final class CapturesStoredValue {
    @GraphStored
    var personalities: [String] = ["calm"]

    var personalityDisplayValueNode = Computed<String>(constant: "")

    var personalityDisplayValue: String {
      personalityDisplayValueNode.wrappedValue
    }

    init() {
      self.personalityDisplayValueNode = .init { [personalities = self.personalities] _ in
        Self.makeMultipleSelectionDisplayValue(from: personalities)
      }
    }

    static func makeMultipleSelectionDisplayValue(from personalities: [String]) -> String {
      personalities.joined(separator: ",")
    }
  }

  final class CapturesStoredNode {
    @GraphStored
    var personalities: [String] = ["calm"]

    var personalityDisplayValueNode = Computed<String>(constant: "")

    var personalityDisplayValue: String {
      personalityDisplayValueNode.wrappedValue
    }

    init() {
      self.personalityDisplayValueNode = .init { [personalities = self.$personalities] _ in
        Self.makeMultipleSelectionDisplayValue(from: personalities.wrappedValue)
      }
    }

    static func makeMultipleSelectionDisplayValue(from personalities: [String]) -> String {
      personalities.joined(separator: ",")
    }
  }

  @Test
  func capturingStoredValueDoesNotBecomeComputedDependency() {
    let model = CapturesStoredValue()

    #expect(model.personalityDisplayValue == "calm")
    #expect(model.personalityDisplayValueNode.incomingEdges.isEmpty)

    model.personalities = ["active"]

    // Capturing the wrapped value is a snapshot. It does not create a dependency edge.
    #expect(model.personalityDisplayValue == "calm")
    #expect(model.personalityDisplayValueNode.incomingEdges.isEmpty)
  }

  @Test
  func capturingStoredNodeAndReadingItInsideRuleBecomesComputedDependency() {
    let model = CapturesStoredNode()

    #expect(model.personalityDisplayValue == "calm")
    #expect(model.personalityDisplayValueNode.incomingEdges.count == 1)

    model.personalities = ["active"]

    // Capturing the node and reading wrappedValue during the rule creates a dependency edge.
    #expect(model.personalityDisplayValue == "active")
    #expect(model.personalityDisplayValueNode.incomingEdges.count == 1)
  }
}
