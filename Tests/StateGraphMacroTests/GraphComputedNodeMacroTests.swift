import MacroTesting
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import StateGraphMacro

final class GraphComputedNodeMacroTests: XCTestCase {

  override func invokeTest() {
    withMacroTesting(
      record: false,
      macros: ["GraphComputedNode": GraphComputedNodeMacro.self]
    ) {
      super.invokeTest()
    }
  }

  func test_explicit_node_keeps_projected_initialization() {
    assertMacro {
      """
      final class Model {
        @GraphComputedNode
        var doubled: Int

        init(node: Computed<Int>) {
          $doubled = node
        }
      }
      """
    } expansion: {
      """
      final class Model {
        var doubled: Int {
          get {
            return $doubled.wrappedValue
          }
        }

        @GraphIgnored let $doubled: Computed<Int>

        init(node: Computed<Int>) {
          $doubled = node
        }
      }
      """
    }
  }

  func test_public_projection_preserves_access_control() {
    assertMacro {
      """
      public struct Model {
        @GraphComputedNode
        public var doubled: Int
      }
      """
    } expansion: {
      """
      public struct Model {
        public var doubled: Int {
          get {
            return $doubled.wrappedValue
          }
        }

        @GraphIgnored
          public let $doubled: Computed<Int>
      }
      """
    }
  }

  func test_body_diagnostic_points_to_graph_computed() {
    assertMacroExpansion(
      """
      final class Model {
        @GraphComputedNode
        var doubled: Int { count * 2 }
      }
      """,
      expandedSource: """
      final class Model {
        var doubled: Int { count * 2 }
      }
      """,
      diagnostics: [
        DiagnosticSpec(
          message: "@GraphComputedNode cannot have a body or property observers; use @GraphComputed for a computed body",
          line: 2,
          column: 3
        )
      ],
      macros: ["GraphComputedNode": GraphComputedNodeMacro.self],
      indentationWidth: .spaces(2)
    )
  }
}
