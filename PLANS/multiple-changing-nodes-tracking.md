# Plan: Track Multiple Changing Nodes

## Background

When using `currentChangingNode()` / `currentChangingNodeInfo()` within tracking handlers (e.g., `withGraphTrackingGroup`), only the **first** node that triggers the callback is captured.

## Current Behavior

When multiple nodes change simultaneously before the callback executes:

```swift
node1.wrappedValue = 100
node2.wrappedValue = 200
node3.wrappedValue = 300
```

**Result:**
- Callback is triggered **once** (due to `TrackingRegistration` invalidation)
- Only `node1` is captured via `currentChangingNode()`
- `node2` and `node3` changes are ignored (early return in `perform()`)

### Why This Happens

In `TrackingRegistration.perform()`:

```swift
func perform() {
  state.withLock { state in
    guard state.isInvalidated == false else {
      return  // ← node2, node3 hit this early return
    }
    state.isInvalidated = true  // ← node1 sets this
    Task { await closure() }
  }
}
```

## Proposed Enhancement

Track all nodes that changed since the last callback execution.

### Option A: Accumulate in TrackingRegistration

```swift
public final class TrackingRegistration {
  private struct State: Sendable {
    var isInvalidated: Bool = false
    var changedNodes: [any TypeErasedNode] = []  // NEW
    let didChange: @isolated(any) @Sendable () -> Void
  }

  func recordChange(_ node: any TypeErasedNode) {
    state.withLock { state in
      state.changedNodes.append(node)

      guard state.isInvalidated == false else { return }
      state.isInvalidated = true

      let nodes = state.changedNodes
      ChangingNodeContext.$current.withValue(nodes) {
        Task { await state.didChange() }
      }
    }
  }
}
```

### Option B: Use Array-based TaskLocal

```swift
public enum ChangingNodeContext {
  @TaskLocal
  public static var current: [any TypeErasedNode] = []
}

// Caller side (in node setters)
ChangingNodeContext.$current.withValue(ChangingNodeContext.current + [self]) {
  registration.perform()
}
```

### Updated Public API

```swift
/// Returns all nodes that triggered the current tracking callback.
public func currentChangingNodes() -> [any TypeErasedNode] {
  ChangingNodeContext.current
}

/// Returns the most recent node that triggered the change.
public func currentChangingNode() -> (any TypeErasedNode)? {
  ChangingNodeContext.current.last
}

/// Returns debug info for all changing nodes.
public func currentChangingNodeInfos() -> [NodeInfo] {
  currentChangingNodes().map { $0.info }
}
```

## Trade-offs

| Aspect | Current (Single Node) | Proposed (Multiple Nodes) |
|--------|----------------------|---------------------------|
| Simplicity | Simple | More complex |
| Memory | Minimal | Accumulates nodes |
| Use Case | "What triggered this?" | "What all changed?" |
| Breaking Change | N/A | API change if modifying return type |

## Open Questions

1. Is tracking all changed nodes actually needed for any use case?
2. Should we preserve backward compatibility with single-node API?
3. Performance implications of accumulating nodes?

## Test Case

A test exists to verify current behavior:

```swift
// Tests/StateGraphTests/GraphTrackingGroupTests.swift
func multipleSimultaneousChanges() async throws
```

## Status

**Current Implementation:** Single node tracking (first node only)
**This Plan:** Document potential enhancement for future consideration
