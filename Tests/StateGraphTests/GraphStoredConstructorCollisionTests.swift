import Testing
import StateGraph

/// Verifies that inferred graph storage cannot bind to a client-owned factory.
@Suite("@GraphStored constructor name collisions")
struct GraphStoredConstructorCollisionTests {

  @Test func inferred_storage_uses_the_library_node_when_a_client_factory_has_the_same_name() {
    /// Exercises inferred and annotated declarations under the same name collision.
    final class Model {
      @GraphStored var inferred = 0
      @GraphStored var explicit: Int = 0
    }

    collidingConstructorCalls.withLock { $0 = 0 }
    let model = Model()

    // A runtime type check lets the unfixed macro compile so the regression also
    // demonstrates the stale Computed result produced by the shadowing factory.
    #expect(ObjectIdentifier(type(of: model.$inferred)) == ObjectIdentifier(StateGraph::Stored<Int>.self))
    #expect(ObjectIdentifier(type(of: model.$explicit)) == ObjectIdentifier(StateGraph::Stored<Int>.self))
    #expect(collidingConstructorCalls.withLock { $0 } == 0)

    let evaluations = OSAllocatedUnfairLock(initialState: (inferred: 0, explicit: 0))
    let inferredComputed = Computed { [node = model.$inferred] _ in
      evaluations.withLock { $0.inferred += 1 }
      return node.wrappedValue * 2
    }
    let explicitComputed = Computed { [node = model.$explicit] _ in
      evaluations.withLock { $0.explicit += 1 }
      return node.wrappedValue * 2
    }

    #expect(inferredComputed.wrappedValue == 0)
    #expect(explicitComputed.wrappedValue == 0)
    model.inferred = 0
    model.explicit = 0
    #expect(inferredComputed.wrappedValue == 0)
    #expect(explicitComputed.wrappedValue == 0)
    #expect(evaluations.withLock { $0.inferred } == 1)
    #expect(evaluations.withLock { $0.explicit } == 1)

    model.inferred = 3
    model.explicit = 3
    #expect(model.inferred == 3)
    #expect(model.explicit == 3)
    #expect(inferredComputed.wrappedValue == 6)
    #expect(explicitComputed.wrappedValue == 6)
    #expect(evaluations.withLock { $0.inferred } == 2)
    #expect(evaluations.withLock { $0.explicit } == 2)

    model.inferred = 3
    model.explicit = 3
    #expect(inferredComputed.wrappedValue == 6)
    #expect(explicitComputed.wrappedValue == 6)
    #expect(evaluations.withLock { $0.inferred } == 2)
    #expect(evaluations.withLock { $0.explicit } == 2)
  }

  @Test func inferred_storage_resolves_the_module_when_a_local_type_has_the_same_name() {
    /// Shadows the module's spelling in the lexical scope of the macro expansion.
    enum StateGraph {}

    /// Requires the generated constructor to resolve the module rather than the local type.
    final class Model {
      @GraphStored var count = 0
    }

    let model = Model()
    let node: StateGraph::Stored<Int> = model.$count
    #expect(ObjectIdentifier(type(of: node)) == ObjectIdentifier(StateGraph::Stored<Int>.self))

    let evaluations = OSAllocatedUnfairLock(initialState: 0)
    let computed = Computed { [node] _ in
      evaluations.withLock { $0 += 1 }
      return node.wrappedValue * 2
    }

    #expect(computed.wrappedValue == 0)
    model.count = 3
    #expect(model.count == 3)
    #expect(computed.wrappedValue == 6)
    #expect(evaluations.withLock { $0 } == 2)
  }
}

/// Counts calls to the file-local factory without affecting other test files.
private let collidingConstructorCalls = OSAllocatedUnfairLock(initialState: 0)

/// Models a client factory with the imported graph node constructor's spelling.
private func Stored<Value: Sendable>(
  name: StaticString?,
  wrappedValue: Value
) -> ConstructorShadowBox<Value> {
  collidingConstructorCalls.withLock { $0 += 1 }
  return ConstructorShadowBox(wrappedValue)
}

/// Provides mutable storage without dependency tracking, matching the reported collision.
private final class ConstructorShadowBox<Value: Sendable>: Sendable {
  private let lock: OSAllocatedUnfairLock<Value>

  init(_ value: Value) {
    lock = .init(initialState: value)
  }

  var wrappedValue: Value {
    get { lock.withLock { $0 } }
    set { lock.withLock { $0 = newValue } }
  }
}
