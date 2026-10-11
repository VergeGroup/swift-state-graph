import Foundation
import Testing
import StateGraph

/// Exercises inferred `@GraphStored` declarations through the actual macro and graph nodes.
@Suite("@GraphStored initializer type inference")
struct GraphStoredInferenceTests {

  @Test func literals_static_members_and_factory_results_keep_their_types() {
    /// Combines inferred expressions with declarations that require contextual types.
    final class Model {
      @GraphStored var count = 0
      @GraphStored var title = "initial"
      @GraphStored var createdAt = Date.now
      @GraphStored var date = GraphStoredInferenceTests.makeDate()

      @GraphStored var fraction: Float = 0.5
      @GraphStored var items: [Int] = []
      @GraphStored var optionalValue: Int? = nil
      @GraphStored var comparison: ComparisonResult = .orderedSame
    }

    let before = Date.now
    let model = Model()
    let after = Date.now
    let countNode: Stored<Int> = model.$count
    let titleNode: Stored<String> = model.$title
    let dateNode: Stored<Date> = model.$date
    let fractionNode: Stored<Float> = model.$fraction

    #expect(countNode.wrappedValue == 0)
    #expect(titleNode.wrappedValue == "initial")
    #expect(model.createdAt >= before && model.createdAt <= after)
    #expect(dateNode.wrappedValue == Date(timeIntervalSince1970: 60))
    #expect(fractionNode.wrappedValue == 0.5)
    #expect(model.items.isEmpty)
    #expect(model.optionalValue == nil)
    #expect(model.comparison == .orderedSame)

    let evaluations = OSAllocatedUnfairLock(initialState: 0)
    let computed = Computed { [countNode] _ in
      evaluations.withLock { $0 += 1 }
      return countNode.wrappedValue * 2
    }

    #expect(computed.wrappedValue == 0)
    model.count = 0
    #expect(computed.wrappedValue == 0)
    #expect(evaluations.withLock { $0 } == 1)
    model.count = 3
    #expect(computed.wrappedValue == 6)
    #expect(evaluations.withLock { $0 } == 2)
  }

  @Test func inferred_equatable_values_match_explicit_comparison() {
    /// Uses the same custom value with and without a property type annotation.
    final class Model {
      @GraphStored var inferred = Point(x: 1, y: 2)
      @GraphStored var explicit: Point = .init(x: 1, y: 2)
    }

    let model = Model()
    let evaluations = OSAllocatedUnfairLock(initialState: 0)
    let computed = Computed { [inferred = model.$inferred, explicit = model.$explicit] _ in
      evaluations.withLock { $0 += 1 }
      return inferred.wrappedValue.x + explicit.wrappedValue.x
    }

    #expect(computed.wrappedValue == 2)
    model.inferred = Point(x: 1, y: 2)
    model.explicit = Point(x: 1, y: 2)
    #expect(computed.wrappedValue == 2)
    #expect(evaluations.withLock { $0 } == 1)

    model.inferred = Point(x: 3, y: 2)
    #expect(computed.wrappedValue == 4)
    #expect(evaluations.withLock { $0 } == 2)
    model.explicit = Point(x: 3, y: 2)
    #expect(computed.wrappedValue == 6)
    #expect(evaluations.withLock { $0 } == 3)
  }

  @Test func inferred_reference_values_choose_identity_or_equatable_comparison() {
    /// Distinguishes the identity comparator from the Equatable reference comparator.
    final class Model {
      @GraphStored var reference = Reference(value: 1)
      @GraphStored var explicitReference: Reference = .init(value: 1)
      @GraphStored var equatable = EquatableReference(value: 1)
      @GraphStored var explicitEquatable: EquatableReference = .init(value: 1)
    }

    let model = Model()
    let evaluations = OSAllocatedUnfairLock(initialState: 0)
    let computed = Computed {
      [reference = model.$reference, explicitReference = model.$explicitReference,
      equatable = model.$equatable, explicitEquatable = model.$explicitEquatable] _ in
      evaluations.withLock { $0 += 1 }
      return reference.wrappedValue.value + explicitReference.wrappedValue.value
        + equatable.wrappedValue.value + explicitEquatable.wrappedValue.value
    }

    #expect(computed.wrappedValue == 4)
    model.reference = model.reference
    model.explicitReference = model.explicitReference
    model.equatable = EquatableReference(value: 1)
    model.explicitEquatable = EquatableReference(value: 1)
    #expect(computed.wrappedValue == 4)
    #expect(evaluations.withLock { $0 } == 1)

    // A new non-Equatable object changes identity even when its payload is equal.
    model.reference = Reference(value: 1)
    #expect(computed.wrappedValue == 4)
    #expect(evaluations.withLock { $0 } == 2)
    model.explicitReference = Reference(value: 1)
    #expect(computed.wrappedValue == 4)
    #expect(evaluations.withLock { $0 } == 3)

    model.equatable = EquatableReference(value: 2)
    #expect(computed.wrappedValue == 5)
    #expect(evaluations.withLock { $0 } == 4)
    model.explicitEquatable = EquatableReference(value: 2)
    #expect(computed.wrappedValue == 6)
    #expect(evaluations.withLock { $0 } == 5)
  }

  @Test func inferred_non_equatable_values_publish_every_assignment() {
    /// Uses an unconstrained value rather than an Equatable or reference overload.
    final class Model {
      @GraphStored var payload = Payload(value: 1)
      @GraphStored var explicit: Payload = .init(value: 1)
    }

    let model = Model()
    let evaluations = OSAllocatedUnfairLock(initialState: 0)
    let computed = Computed { [payload = model.$payload, explicit = model.$explicit] _ in
      evaluations.withLock { $0 += 1 }
      return payload.wrappedValue.value + explicit.wrappedValue.value
    }

    #expect(computed.wrappedValue == 2)
    model.payload = Payload(value: 1)
    #expect(computed.wrappedValue == 2)
    #expect(evaluations.withLock { $0 } == 2)
    model.explicit = Payload(value: 1)
    #expect(computed.wrappedValue == 2)
    #expect(evaluations.withLock { $0 } == 3)
  }

  @Test func inferred_optional_values_track_some_and_nil_assignments() {
    /// Supplies an optional type through the initializer rather than an annotation.
    final class Model {
      @GraphStored var selection = Optional<Int>.none
    }

    let model = Model()
    let node: Stored<Int?> = model.$selection
    let evaluations = OSAllocatedUnfairLock(initialState: 0)
    let computed = Computed { [node] _ in
      evaluations.withLock { $0 += 1 }
      return node.wrappedValue ?? -1
    }

    #expect(node.wrappedValue == nil)
    #expect(computed.wrappedValue == -1)
    model.selection = nil
    #expect(computed.wrappedValue == -1)
    #expect(evaluations.withLock { $0 } == 1)
    model.selection = 7
    #expect(computed.wrappedValue == 7)
    model.selection = nil
    #expect(computed.wrappedValue == -1)
    #expect(evaluations.withLock { $0 } == 3)
  }

  @Test func initializer_inference_works_inside_generic_value_owners() {
    /// Keeps the enclosing generic parameter in an inferred array's element type.
    struct Model<Element: SendableMetatype> {
      @GraphStored var elements = Array<Element>()

      init() {}
    }

    let model = Model<Int>()
    let node: Stored<[Int]> = model.$elements
    #expect(node.wrappedValue.isEmpty)
    model.elements.append(3)
    #expect(model.elements == [3])
    #expect(node.wrappedValue == [3])
  }

  @Test func inferred_default_evaluation_matches_explicit_per_instance_and_keeps_node_identity() {
    /// Assigns both properties before a required field completes definite initialization.
    final class Model {
      @GraphStored var inferred = DefaultFactory.makeInferredReference()
      @GraphStored var explicit: Reference = DefaultFactory.makeExplicitReference()
      let name: String
      var nodeIdentifiers: [ObjectIdentifier] = []
      var defaultReferences: [Reference] = []

      init() {
        let inferredNode = ObjectIdentifier($inferred)
        let explicitNode = ObjectIdentifier($explicit)
        let inferredDefault = $inferred.wrappedValue
        let explicitDefault = $explicit.wrappedValue
        inferred = Reference(value: 100)
        explicit = Reference(value: 200)
        name = "model"
        nodeIdentifiers = [inferredNode, explicitNode]
        defaultReferences = [inferredDefault, explicitDefault]
      }
    }

    DefaultFactory.evaluations.withLock { $0 = (inferred: 0, explicit: 0) }
    let first = Model()
    // Existing typed declarations evaluate the default for both backing storage and
    // the original property's init accessor. Inference must preserve that behavior.
    #expect(DefaultFactory.evaluations.withLock { $0.inferred } == 2)
    #expect(DefaultFactory.evaluations.withLock { $0.explicit } == 2)
    let second = Model()
    #expect(DefaultFactory.evaluations.withLock { $0.inferred } == 4)
    #expect(DefaultFactory.evaluations.withLock { $0.explicit } == 4)

    for model in [first, second] {
      #expect(model.inferred.value == 100)
      #expect(model.explicit.value == 200)
      #expect(model.nodeIdentifiers == [
        ObjectIdentifier(model.$inferred), ObjectIdentifier(model.$explicit),
      ])
    }
    #expect(first.$inferred !== second.$inferred)
    #expect(first.inferred !== second.inferred)
    #expect(first.$explicit !== second.$explicit)
    #expect(first.defaultReferences[0] !== second.defaultReferences[0])
    #expect(first.defaultReferences[1] !== second.defaultReferences[1])
  }

  @Test func inferred_property_observers_keep_assignment_and_transaction_semantics() {
    /// Lets an inferred observer mutate another inferred property in one transaction.
    final class Model {
      @GraphStored var count = 0 {
        willSet(next) {
          events.append("will \(count)->\(next)")
        }
        didSet(previous) {
          total += count - previous
          events.append("did \(previous)->\(count)")
        }
      }
      @GraphStored var total = 0
      var events: [String] = []
    }

    let model = Model()
    #expect(throws: InitializationFailure.self) {
      try withGraphTransaction { () throws(InitializationFailure) -> Void in
        model.count = 2
        model.count = 2
        #expect(model.total == 2)
        throw InitializationFailure()
      }
    }

    #expect(model.count == 0)
    #expect(model.total == 0)
    #expect(model.events == ["will 0->2", "did 0->2", "will 2->2", "did 2->2"])
  }

  @Test func inferred_assignments_preserve_throwing_and_failable_initializer_cleanup() {
    /// Releases its first field after an inferred init-accessor assignment throws.
    final class ThrowingModel {
      let tracked: Tracked
      @GraphStored var value = 0
      let required: Int

      init(tracked: Tracked) throws {
        self.tracked = tracked
        value = 1
        throw InitializationFailure()
      }
    }

    /// Releases its first field after an inferred init-accessor assignment returns nil.
    final class FailableModel {
      let tracked: Tracked
      @GraphStored var value = 0
      let required: Int

      init?(tracked: Tracked) {
        self.tracked = tracked
        value = 1
        return nil
      }
    }

    let throwingCounter = DeinitCounter()
    #expect(throws: InitializationFailure.self) {
      _ = try ThrowingModel(tracked: Tracked(throwingCounter))
    }
    #expect(throwingCounter.count == 1)

    let failableCounter = DeinitCounter()
    #expect(FailableModel(tracked: Tracked(failableCounter)) == nil)
    #expect(failableCounter.count == 1)
  }

  @Test func inferred_properties_preserve_actor_isolation() async {
    /// Owns an inferred integer behind ordinary actor isolation.
    actor Model {
      @GraphStored var count = 0

      func increment() -> Int {
        count += 1
        return count
      }
    }

    let model = Model()
    #expect(await model.count == 0)
    #expect(await model.increment() == 1)
    #expect(await model.count == 1)
  }

  @Test @MainActor func inferred_properties_work_in_main_actor_owners() {
    /// Keeps the property and its inferred backing node on the owner's global actor.
    @MainActor final class Model {
      @GraphStored static var sharedCount = 0
      @GraphStored var count = 0
      @GraphStored var date = Date.now
    }

    let model = Model()
    let node: Stored<Int> = model.$count
    Model.sharedCount = 4
    #expect(Model.$sharedCount.wrappedValue == 4)
    model.count = 3
    #expect(node.wrappedValue == 3)
    model.date = Date(timeIntervalSince1970: 60)
    #expect(model.date == Date(timeIntervalSince1970: 60))
  }

  private static func makeDate() -> Date {
    Date(timeIntervalSince1970: 60)
  }

  /// A custom Equatable value whose comparator cannot come from literal syntax.
  private struct Point: Equatable {
    var x: Int
    var y: Int
  }

  /// A value with no equality conformance, so every assignment must publish.
  private struct Payload {
    var value: Int
  }

  /// An ordinary reference value that compares through `Stored`'s identity overload.
  private final class Reference {
    let value: Int

    init(value: Int) {
      self.value = value
    }
  }

  /// A reference value whose equality deliberately ignores instance identity.
  private final class EquatableReference: Equatable {
    let value: Int

    init(value: Int) {
      self.value = value
    }

    static func == (lhs: EquatableReference, rhs: EquatableReference) -> Bool {
      lhs.value == rhs.value
    }
  }

  /// Counts initializer calls without sharing mutable state outside its lock.
  private enum DefaultFactory {
    static let evaluations = OSAllocatedUnfairLock(initialState: (inferred: 0, explicit: 0))

    static func makeInferredReference() -> Reference {
      let value = evaluations.withLock {
        $0.inferred += 1
        return $0.inferred
      }
      return Reference(value: value)
    }

    static func makeExplicitReference() -> Reference {
      let value = evaluations.withLock {
        $0.explicit += 1
        return $0.explicit
      }
      return Reference(value: value)
    }
  }

  /// Marks the throwing path through an incompletely initialized model.
  private struct InitializationFailure: Error {}

  /// Counts destruction synchronously within one initializer-cleanup test.
  private final class DeinitCounter {
    var count = 0
  }

  /// Records its destruction after a model initializer exits early.
  private final class Tracked {
    let counter: DeinitCounter

    init(_ counter: DeinitCounter) {
      self.counter = counter
    }

    deinit {
      counter.count += 1
    }
  }
}
