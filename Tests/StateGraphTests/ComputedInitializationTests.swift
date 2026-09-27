import Foundation
import Observation
import Testing

import StateGraph

@Suite("Computed model initialization")
struct ComputedInitializationTests {

  /// Requests rollback after a successfully constructed model has escaped its transaction.
  private enum InitializationError: Error {
    case rollback
  }

  /// Records synchronous callbacks without introducing unsynchronized Sendable captures.
  private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
      storage = value
    }

    var value: Value {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }

    func update(_ body: (inout Value) -> Void) {
      lock.lock()
      defer { lock.unlock() }
      body(&storage)
    }
  }

  /// Runs a supplied action when an initial value is replaced or initialization fails.
  private final class DeinitAction {
    private let action: () -> Void

    init(_ action: @escaping () -> Void = {}) {
      self.action = action
    }

    deinit {
      action()
    }
  }

  /// Lets a replaced value inspect its former node without retaining it in a cycle.
  private final class WeakNode {
    weak var value: Stored<DeinitAction>?
  }

  @Test
  func allDefaultModelCanAssignDuringComputedEvaluation() {
    final class Model {
      @GraphStored var count: Int = 0

      init(count: Int) {
        self.count = count
      }
    }

    let computed = Computed<Model> { _ in Model(count: 42) }
    let model = computed.wrappedValue

    #expect(model.count == 42)
    #expect(computed.wrappedValue === model)
  }

  @Test
  func forwardingAndOrdinaryInitializerAssignmentsKeepNodeIdentity() {
    final class Model {
      @GraphStored var count: Int = 0
      @GraphStored var optionalValue: Int?
      @GraphStored var implicitlyUnwrappedValue: Int!
      @GraphStored var requiredValue: Int
      let initialNodeIdentifier: ObjectIdentifier

      init() {
        let identifier = ObjectIdentifier($count)
        // The required properties keep these assignments in the init accessor.
        count = 10
        optionalValue = 11
        implicitlyUnwrappedValue = 12
        requiredValue = 13
        initialNodeIdentifier = identifier
        // Now self is initialized, so this assignment uses the ordinary setter.
        count = 14
      }
    }

    let computed = Computed<Model> { _ in Model() }
    let model = computed.wrappedValue

    #expect(model.count == 14)
    #expect(model.optionalValue == 11)
    #expect(model.implicitlyUnwrappedValue == 12)
    #expect(model.requiredValue == 13)
    #expect(ObjectIdentifier(model.$count) == model.initialNodeIdentifier)
  }

  @Test
  func structInitializerCanAssignDefaultsAndOptionals() {
    struct Model {
      @GraphStored var count: Int = 0
      @GraphStored var optionalValue: Int?

      init(count: Int) {
        self.count = count
        optionalValue = count + 1
      }
    }

    let computed = Computed<Model> { _ in Model(count: 4) }
    let model = computed.wrappedValue

    #expect(model.count == 4)
    #expect(model.optionalValue == 5)
  }

  @Test
  func setterObserversReceiveTheInitialOldValue() {
    final class Model {
      @GraphStored var count: Int = 0 {
        willSet(nextValue) {
          events.append("willSet:\(nextValue)")
        }
        didSet(previousValue) {
          events.append("didSet:\(previousValue)->\(count)")
        }
      }
      var events: [String] = []

      init(count: Int) {
        self.count = count
      }
    }

    let computed = Computed<Model> { _ in Model(count: 9) }
    // Retain the result: didSet's explicit count read makes this node a dependency.
    let model = computed.wrappedValue

    #expect(model.count == 9)
    #expect(model.events == ["willSet:9", "didSet:0->9"])

    model.count = 10
    #expect(model.events == ["willSet:9", "didSet:0->9", "willSet:10", "didSet:9->10"])
  }

  @Test
  func directInitializationSkipsComparatorUntilAnOrdinaryAssignment() {
    let comparisons = LockedBox<[String]>([])
    let computed = Computed<Stored<Int>> { _ in
      let node = Stored(wrappedValue: 0) { oldValue, newValue in
        comparisons.update { $0.append("\(oldValue)->\(newValue)") }
        return oldValue != newValue
      }
      node.wrappedValue = 1
      node.wrappedValue = 2
      return node
    }
    let node = computed.wrappedValue

    #expect(node.wrappedValue == 2)
    #expect(comparisons.value.isEmpty)

    node.wrappedValue = 3
    #expect(comparisons.value == ["2->3"])
  }

  @Test
  func nestedEvaluationRestoresItsParentInitializationScope() {
    /// Retains both evaluated nodes while their parent computation is active.
    struct Nodes {
      let outerNode: Stored<Int>
      let innerComputed: Computed<Stored<Int>>
      let innerNode: Stored<Int>
    }

    let computed = Computed<Nodes> { _ in
      let outerNode = Stored(wrappedValue: 0)
      outerNode.wrappedValue = 1

      let innerComputed = Computed<Stored<Int>> { _ in
        let innerNode = Stored(wrappedValue: 0)
        innerNode.wrappedValue = 2
        return innerNode
      }
      let innerNode = innerComputed.wrappedValue
      outerNode.wrappedValue = 3

      return Nodes(
        outerNode: outerNode,
        innerComputed: innerComputed,
        innerNode: innerNode
      )
    }
    let nodes = computed.wrappedValue

    #expect(nodes.outerNode.wrappedValue == 3)
    #expect(nodes.innerNode.wrappedValue == 2)
    #expect(nodes.innerComputed.wrappedValue === nodes.innerNode)
  }

  @Test
  func constructedModelRetainsInitialValuesAfterTransactionRollback() throws {
    final class Model {
      @GraphStored var count: Int = 0

      init(count: Int) {
        self.count = count
      }
    }

    let source = Stored(wrappedValue: 1)
    let computed = Computed<Model> { _ in Model(count: source.wrappedValue) }
    var retainedModel: Model?

    #expect(throws: InitializationError.self) {
      try withGraphTransaction {
        source.wrappedValue = 7
        retainedModel = computed.wrappedValue
        #expect(retainedModel?.count == 7)
        throw InitializationError.rollback
      }
    }

    let model = try #require(retainedModel)
    #expect(source.wrappedValue == 1)
    #expect(model.count == 7)

    // Once construction has finished, ordinary assignments still join the transaction.
    #expect(throws: InitializationError.self) {
      try withGraphTransaction {
        model.count = 8
        #expect(model.count == 8)
        throw InitializationError.rollback
      }
    }
    #expect(model.count == 7)

    withGraphTransaction {
      model.count = 9
    }
    #expect(model.count == 9)
    #expect(computed.wrappedValue.count == 1)
  }

  @Test
  @MainActor
  func constructedNodeSupportsOrdinaryObserversAndDependencies() async {
    let computed = Computed<Stored<Int>> { _ in
      let node = Stored(wrappedValue: 0)
      node.wrappedValue = 2
      return node
    }
    let node = computed.wrappedValue
    let derived = Computed<Int> { _ in node.wrappedValue * 2 }
    let assignments = LockedBox<[String]>([])
    let observationDelivered = TestSignal()

    node.onDidSet { oldValue, newValue in
      assignments.update { $0.append("\(oldValue)->\(newValue)") }
    }
    withObservationTracking {
      _ = node.wrappedValue
    } onChange: {
      observationDelivered.signal()
    }
    #expect(derived.wrappedValue == 4)

    node.wrappedValue = 3

    #expect(derived.wrappedValue == 6)
    #expect(assignments.value == ["2->3"])
    #expect(await observationDelivered.wait(for: .seconds(5)))
  }

  @Test
  @MainActor
  func mainActorModelCanBeInitializedByASynchronousComputedRead() {
    @MainActor
    final class Model {
      @GraphStored var count: Int = 0

      init(count: Int) {
        self.count = count
      }
    }

    let computed = Computed<Model> { _ in
      MainActor.assumeIsolated {
        Model(count: 12)
      }
    }
    let model = computed.wrappedValue

    #expect(model.count == 12)
  }

  @Test
  func concurrentReadsSurviveInitializationScopeExpiration() async throws {
    let publishedNode = LockedBox<Stored<Int>?>(nil)
    let evaluationFinished = LockedBox(false)
    let initialReadsMatched = LockedBox(true)
    let finalRead = LockedBox<Int?>(nil)
    let nodePublished = TestThreadSignal()
    let readerReadyForUpdate = TestSignal()
    let ordinaryAssignmentFinished = TestThreadSignal()
    let readerFinished = TestSignal()

    Thread {
      defer { readerFinished.signal() }
      let deadline = Date().addingTimeInterval(10)
      guard nodePublished.wait(until: deadline) else { return }

      // Each getter may load a weak scope while the computing thread releases it.
      // The descriptor never waits for this reader while holding graph read access.
      repeat {
        guard let node = publishedNode.value else { return }
        if node.wrappedValue != 1 {
          initialReadsMatched.update { $0 = false }
        }
      } while !evaluationFinished.value && Date() < deadline

      guard evaluationFinished.value, let node = publishedNode.value else { return }
      if node.wrappedValue != 1 {
        initialReadsMatched.update { $0 = false }
      }
      readerReadyForUpdate.signal()
      guard ordinaryAssignmentFinished.wait(until: deadline) else { return }
      finalRead.update { $0 = node.wrappedValue }
    }.start()

    var computedResults: [Computed<Stored<Int>>] = []
    for _ in 0..<32 {
      let computed = Computed<Stored<Int>> { _ in
        let node = Stored(wrappedValue: 0)
        node.wrappedValue = 1
        publishedNode.update { $0 = node }
        nodePublished.signal()
        return node
      }
      computedResults.append(computed)
      _ = computed.wrappedValue
    }
    evaluationFinished.update { $0 = true }

    defer { ordinaryAssignmentFinished.signal() }
    let readerIsReady = await readerReadyForUpdate.wait(for: .seconds(10))
    #expect(readerIsReady)
    guard readerIsReady else { return }

    let computed = try #require(computedResults.last)
    let node = computed.wrappedValue
    #expect(node === publishedNode.value)
    node.wrappedValue = 2
    ordinaryAssignmentFinished.signal()

    #expect(await readerFinished.wait(for: .seconds(10)))
    #expect(initialReadsMatched.value)
    #expect(finalRead.value == 2)
    withExtendedLifetime(computedResults) {}
  }

  @Test
  func failedInitializersDestroyTheirPropertiesOnce() {
    final class ThrowingModel {
      let tracked: DeinitAction
      @GraphStored var count: Int = 0
      let requiredValue: Int

      init(tracked: DeinitAction) throws {
        self.tracked = tracked
        count = 1
        throw InitializationError.rollback
      }
    }

    final class FailableModel {
      let tracked: DeinitAction
      @GraphStored var count: Int = 0
      let requiredValue: Int

      init?(tracked: DeinitAction) {
        self.tracked = tracked
        count = 1
        return nil
      }
    }

    let destroyed = LockedBox(0)
    let throwing = Computed<ThrowingModel?> { _ in
      try? ThrowingModel(tracked: DeinitAction { destroyed.update { $0 += 1 } })
    }
    let failable = Computed<FailableModel?> { _ in
      FailableModel(tracked: DeinitAction { destroyed.update { $0 += 1 } })
    }

    #expect(throwing.wrappedValue == nil)
    #expect(failable.wrappedValue == nil)
    #expect(destroyed.value == 2)
  }

  @Test
  func replacedInitialValueIsReleasedOutsideItsNodeLock() {
    let releasedOutsideLock = LockedBox(false)
    let computed = Computed<Stored<DeinitAction>> { _ in
      let weakNode = WeakNode()
      let node = Stored(wrappedValue: DeinitAction {
        guard let node = weakNode.value else { return }
        if node.lock.lockIfAvailable() {
          node.lock.unlock()
          releasedOutsideLock.update { $0 = true }
        }
      })
      weakNode.value = node
      node.wrappedValue = DeinitAction()
      return node
    }
    let node = computed.wrappedValue

    #expect(releasedOutsideLock.value)
    withExtendedLifetime(node) {}
  }
}
