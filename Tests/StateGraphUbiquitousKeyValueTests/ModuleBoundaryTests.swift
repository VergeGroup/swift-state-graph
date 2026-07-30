import StateGraphUbiquitousKeyValue
import Testing

/// Verifies the public import contract of the optional extension module.
@Suite("StateGraphUbiquitousKeyValue module")
struct StateGraphUbiquitousKeyValueModuleTests {
  @Test("The extension module re-exports StateGraph")
  func reexportsStateGraph() {
    let value = Stored(wrappedValue: 42)

    #expect(value.wrappedValue == 42)
  }
}
