# Tracking Registrations

Understand how one tracking pass records node reads and turns them into a one-shot change notification.

## Overview

Public APIs such as ``withGraphTrackingGroup(_:isolation:)`` and
``withGraphTrackingMap(_:filter:onChange:isolation:)`` continuously re-run work when the
State Graph nodes read by that work change. A ``TrackingRegistration`` is the internal record
that connects one execution of that work to the nodes it read.

You don't create or retain registrations directly. StateGraph creates a fresh registration for
each tracking pass and manages it through the public tracking APIs:

```swift
let subscription = withGraphTracking {
  withGraphTrackingGroup {
    print(model.count)
  }
}
```

In this example, the registration belongs to one execution of the group handler. The returned
subscription owns the overall observation lifetime; the registration only describes the node
reads made by that particular execution.

## Responsibilities

Several objects participate in continuous tracking, but they have different lifetimes:

| Component | Responsibility |
| --- | --- |
| `AnyCancellable` and `GraphTrackingCancellable` | Own the overall tracking scope and its nested scopes. |
| ``TrackingRegistration`` | Represent the node reads and change callback for one tracking pass. |
| `ThreadLocal.registration` | Make the current pass visible to synchronous node reads. |
| `Node.trackingRegistrations` | Retain the registrations that have read that node. |
| Handler storage lock | Retain the handler until cancellation and serialize handler execution. |

Keeping these responsibilities separate is important. Cancelling a subscription ends the whole
observation, while invalidating a registration only completes one pass and allows continuous
tracking to establish the next one.

## Lifecycle of a Registration

A registration moves through the following lifecycle:

1. `withStateGraphTracking` creates a registration containing the pass's `didChange` callback.
2. StateGraph installs it in `ThreadLocal.registration` for the synchronous duration of `apply`.
3. Every ``Stored`` or ``Computed`` value read by `apply` inserts that same registration into its
   `trackingRegistrations` set.
4. When an eligible change occurs, the node snapshots and clears its registrations while holding
   the node lock.
5. After releasing the node lock, the node calls `perform()` on each captured registration.
6. The first eligible `perform()` marks the registration invalidated and enqueues `didChange` in a
   task. If the tracking pass inherited an actor, StateGraph returns to that actor. Otherwise the
   callback executes on an unspecified executor.
7. A continuous tracking API runs a new pass with a fresh registration, recording the dependencies
   read by that new execution.

The callback runs after both the node lock and the registration's state lock are released. This
allows the next tracking pass to read graph state or establish nested tracking without re-entering
either lock.

### One-shot invalidation

A registration may be stored by several nodes because one pass can read several values. The first
eligible node invalidation delivers its callback. Later calls to `perform()` on the same
registration do nothing.

This one-shot behavior aggregates changes that occur before the next pass. It also means that
continuous observation must create a fresh registration rather than reusing the invalidated one.
The new pass dynamically replaces the dependency set: only nodes read during that pass participate
in its next invalidation.

## Stored and Computed Nodes

``Stored`` evaluates its notification predicate before invalidating registrations:

- An `Equatable` value notifies when the old and new values differ.
- A non-Equatable reference value notifies when its identity changes.
- A value without an equality or identity comparison notifies on every assignment.

An assignment rejected by the predicate doesn't call `perform()` and leaves the current
registrations attached. Therefore, assigning the same `Int` doesn't exercise registration
invalidation or self-invalidation protection.

``Computed`` captures registrations when it changes from clean to potentially dirty. It clears the
captured set and invalidates those registrations once, even if additional upstream changes arrive
before the computed value is read and recomputed.

## Self-Invalidation

A tracking handler can read a node and then synchronously assign to that same node. In that case,
the node's captured registrations include the registration that is currently executing.

StateGraph compares the registration passed to `perform()` with `ThreadLocal.registration`. It
doesn't invoke the active registration's own callback, which prevents an immediate feedback loop.
Registrations belonging to peer handlers have different identities and continue to receive the
change normally.

The mutated node has already removed the active registration from its set. StateGraph doesn't
restore it automatically, so that handler won't observe another change to the same node until a
different tracked dependency causes a new pass. In DEBUG builds, StateGraph emits a warning for
this condition unless ``StateGraphDiagnostics/isSelfInvalidationWarningEnabled`` is disabled.

> Important: Self-invalidation protection only suppresses the active registration. It doesn't
> detect or stop a cycle formed by multiple handlers that mutate one another's dependencies.

## Concurrent Invalidation and Serialized Reruns

Tracking callbacks can be requested concurrently with a handler that is already running. The
current implementation keeps handler bodies serialized by holding the handler storage lock while
the user handler executes. An overlapping tracking pass waits for that lock.

Because the waiting pass remains inside its own `withStateGraphTracking` scope, it executes with
the fresh registration created for that pass after the lock becomes available. It doesn't hand
the handler execution to the previous pass.

This preserves the following implementation invariant:

> Every rerun must execute with the registration and nested tracking scope created for that pass.

## See Also

- ``withGraphTracking(_:)``
- ``withGraphTrackingGroup(_:isolation:)``
- ``withGraphTrackingMap(_:filter:onChange:isolation:)``
- ``StateGraphDiagnostics/isSelfInvalidationWarningEnabled``
