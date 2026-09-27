import Foundation
import SwiftUI
import Testing
import StateGraph

@Suite
struct ModelInitializationTests {

  @Test func basic() {

    final class StateViewModel {

      @GraphStored
      var optional_variable: Int?

      let shadow_value: Int

      init() {
        self.optional_variable = 0
        self.shadow_value = 0

      }

    }

    _ = StateViewModel()
  }

  @Test func initializer_assignments_keep_the_stored_node() {
    final class Model {
      @GraphStored
      var count: Int = 0 {
        didSet {
          observedChanges.append("\(oldValue)->\(count)")
        }
      }

      let name: String
      var nodeIdentifiers: [ObjectIdentifier] = []
      var observedChanges: [String] = []

      init() {
        let initialNode = ObjectIdentifier($count)
        // `name` is not initialized yet, so this runs the init accessor.
        count = 1
        name = "model"
        nodeIdentifiers = [initialNode, ObjectIdentifier($count)]
        // Every stored property is initialized, so this runs the setter.
        count = 2
        nodeIdentifiers.append(ObjectIdentifier($count))
      }
    }

    let model = Model()

    #expect(model.count == 2)
    #expect(Set(model.nodeIdentifiers) == [ObjectIdentifier(model.$count)])
    // The setter's old value comes from the same node the init accessor wrote.
    #expect(model.observedChanges == ["1->2"])
  }

  // Swift's definite initialization destroys the first stored properties again
  // when an init accessor with an empty `initializes` list has run before an
  // initializer exits early. `tracked` is declared first so a regression
  // over-releases it.

  @Test func throwing_class_initializer_destroys_properties_once() {
    final class Model {
      let tracked: Tracked
      @GraphStored var value: Int = 0
      @GraphStored var optionalValue: Int?
      @GraphStored var implicitlyUnwrappedValue: Int!
      let required: Int

      init(tracked: Tracked, fail: Bool) throws {
        self.tracked = tracked
        value = 1
        if fail {
          throw InitializationFailure()
        }
        required = 1
      }
    }

    let counter = DeinitCounter()
    #expect(throws: InitializationFailure.self) {
      _ = try Model(tracked: Tracked(counter), fail: true)
    }
    #expect(counter.count == 1)
  }

  @Test func failable_class_initializer_destroys_properties_once() {
    final class Model {
      let tracked: Tracked
      @GraphStored var value: Int = 0
      let required: Int

      init?(tracked: Tracked, fail: Bool) {
        self.tracked = tracked
        value = 1
        if fail {
          return nil
        }
        required = 1
      }
    }

    let counter = DeinitCounter()
    #expect(Model(tracked: Tracked(counter), fail: true) == nil)
    #expect(counter.count == 1)
  }

  @Test func throwing_struct_initializer_destroys_properties_once() {
    struct State {
      let tracked: Tracked
      @GraphStored var value: Int = 0
      let required: Int

      init(tracked: Tracked, fail: Bool) throws {
        self.tracked = tracked
        value = 1
        if fail {
          throw InitializationFailure()
        }
        required = 1
      }
    }

    let counter = DeinitCounter()
    #expect(throws: InitializationFailure.self) {
      _ = try State(tracked: Tracked(counter), fail: true)
    }
    #expect(counter.count == 1)
  }

  @Test func subclass_initializer_throwing_before_super_init_destroys_properties_once() {
    class Base {
      init() {}
    }

    final class Model: Base {
      let tracked: Tracked
      @GraphStored var value: Int = 0
      let required: Int

      init(tracked: Tracked, fail: Bool) throws {
        self.tracked = tracked
        value = 1
        if fail {
          throw InitializationFailure()
        }
        required = 1
        super.init()
      }
    }

    let counter = DeinitCounter()
    #expect(throws: InitializationFailure.self) {
      _ = try Model(tracked: Tracked(counter), fail: true)
    }
    #expect(counter.count == 1)
  }

  /// Synthesized decoding must allow transient graph state to retain its default.
  @Test func synthesized_decoding_preserves_excluded_graph_defaults() throws {
    final class Model: Codable {
      @GraphStored var value: Int = 7
      @GraphStored var optionalValue: Int?
      var name: String

      enum CodingKeys: String, CodingKey {
        case name
      }
    }

    let model = try JSONDecoder().decode(Model.self, from: Data(#"{"name":"test"}"#.utf8))
    #expect(model.name == "test")
    #expect(model.value == 7)
    #expect(model.optionalValue == nil)
  }

  @Test func decoding_failure_throws_after_assigning_graph_stored_property() {
    final class Model: Decodable {
      @GraphStored var value: Int = 0
      let name: String

      enum CodingKeys: String, CodingKey {
        case value
        case name
      }

      init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(Int.self, forKey: .value)
        name = try container.decode(String.self, forKey: .name)
      }
    }

    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(Model.self, from: Data(#"{"value": 1}"#.utf8))
    }
  }
}

private struct InitializationFailure: Error {}

/// Counts how many times `Tracked` instances are destroyed.
private final class DeinitCounter {
  var count = 0
}

private final class Tracked {
  let counter: DeinitCounter

  init(_ counter: DeinitCounter) {
    self.counter = counter
  }

  deinit {
    counter.count += 1
  }
}
