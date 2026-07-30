import MacroTesting
import XCTest
@testable import StateGraphNormalizationMacro

final class InitAndUpdateMacroTests: XCTestCase {

  override func invokeTest() {
    withMacroTesting(
      record: false,
      macros: [
        "InitAndUpdate": InitAndUpdateMacro.self,
        "onInit": OnInitMarkerMacro.self,
        "onUpdate": OnUpdateMarkerMacro.self,
      ]
    ) {
      super.invokeTest()
    }
  }

  func test_partitions_init_update_and_shared_statements_in_source_order() {
    assertMacro {
      """
      final class Article {
        let id: Int
        var title: String
        var revision: Int = 0

        @InitAndUpdate
        init(id: Int, title: String, revision: Int) {
          let normalizedTitle = title.trimmingCharacters(in: .whitespaces)
          #onInit {
            self.id = id
          }
          self.title = normalizedTitle
          #onUpdate {
            self.revision = revision
          }
        }
      }
      """
    } expansion: {
      """
      final class Article {
        let id: Int
        var title: String
        var revision: Int = 0
        init(id: Int, title: String, revision: Int) {
          let normalizedTitle = title.trimmingCharacters(in: .whitespaces)
          self.id = id
          self.title = normalizedTitle
        }

        func update(id: Int, title: String, revision: Int) {
          let normalizedTitle = title.trimmingCharacters(in: .whitespaces)
          self.title = normalizedTitle
          self.revision = revision
        }
      }
      """
    }
  }

  func test_preserves_the_order_of_repeated_markers_and_shared_statements() {
    assertMacro {
      """
      class Model {
        @InitAndUpdate
        init(with text: String) {
          print("1")
          #onInit {
            print("onInit1")
          }
          #onInit {
            print("onInit2")
          }
          print("2")
          #onUpdate {
            print("onUpdate1")
          }
          #onUpdate {
            print("onUpdate2")
          }
          print("3")
        }
      }
      """
    } expansion: {
      """
      class Model {
        init(with text: String) {
          print("1")
          print("onInit1")
          print("onInit2")
          print("2")
          print("3")
        }

        func update(with text: String) {
          print("1")
          print("2")
          print("onUpdate1")
          print("onUpdate2")
          print("3")
        }
      }
      """
    }
  }

  func test_preserves_access_parameters_effects_and_generic_constraints() {
    assertMacro {
      """
      struct Snapshot {
        @InitAndUpdate
        public init<Payload>(
          id: Int,
          payload: Payload,
          retries: Int = 0
        ) async throws where Payload: Sendable {
          #onInit {
            self.id = id
          }
          self.payload = payload
          #onUpdate {
            self.retries = retries
          }
        }
      }
      """
    } expansion: {
      """
      struct Snapshot {
        public init<Payload>(
          id: Int,
          payload: Payload,
          retries: Int = 0
        ) async throws where Payload: Sendable {
          self.id = id
          self.payload = payload
        }

        public mutating func update<Payload>(
          id: Int,
          payload: Payload,
          retries: Int = 0
        ) async throws where Payload: Sendable {
          self.payload = payload
          self.retries = retries
        }
      }
      """
    }
  }

  func test_preserves_a_with_argument_label_for_source_snapshots() {
    assertMacro {
      """
      struct Article {
        @InitAndUpdate
        init(with json: JSON) {
          #onInit {
            self.id = json.id
          }
          #onUpdate {
            self.title = json.title
          }
        }
      }
      """
    } expansion: {
      """
      struct Article {
        init(with json: JSON) {
          self.id = json.id
        }

        mutating func update(with json: JSON) {
          self.title = json.title
        }
      }
      """
    }
  }

  func test_rejects_non_initializer_attachment() {
    assertMacro {
      """
      @InitAndUpdate
      func make() {}
      """
    } diagnostics: {
      """
      @InitAndUpdate
      ┬─────────────
      ╰─ 🛑 @InitAndUpdate can only be attached to an initializer
      func make() {}
      """
    }
  }

  func test_rejects_failable_initializer() {
    assertMacro {
      """
      struct Article {
        @InitAndUpdate
        init?(id: Int) {}
      }
      """
    } diagnostics: {
      """
      struct Article {
        @InitAndUpdate
        ╰─ 🛑 @InitAndUpdate does not support failable initializers
        init?(id: Int) {}
      }
      """
    }
  }

  func test_rejects_marker_use_outside_init_and_update() {
    assertMacro {
      """
      func make() {
        #onInit {
          print("onInit")
        }
        #onUpdate {
          print("onUpdate")
        }
      }
      """
    } diagnostics: {
      """
      func make() {
        #onInit {
        ╰─ 🛑 #onInit can only be used in an initializer annotated with @InitAndUpdate
          print("onInit")
        }
        #onUpdate {
        ╰─ 🛑 #onUpdate can only be used in an initializer annotated with @InitAndUpdate
          print("onUpdate")
        }
      }
      """
    }
  }
}
