# Stored Value Mutation

## Status

Open design issue. This note describes current behavior and the constraints for
a future mutation API; it is not a public API proposal.

## Current Behavior

`Stored` exposes its value through a getter and setter. Swift therefore
materializes a nested mutation such as:

```swift
state.entities.add(entity)
```

as a read, a mutation of a temporary value, and a writeback. This preserves the
normal `Stored` setter pipeline, including comparison, graph invalidation,
Observation, tracking callbacks, and `onDidSet`.

For a copy-on-write value such as `Dictionary`, materializing the temporary can
make its backing storage appear shared. Its first mutation may then copy the
backing buffer even when the `Stored` node is the only semantic owner. That
first copy is required whenever another live value really does share the
buffer; preserving value semantics is more important than eliminating every
copy. The optimization target is avoiding copies introduced only by the
getter/writeback mechanism and avoiding repeated copies within one logical
mutation.

The getter and setter do not together form one atomic read-modify-write
operation. Two writers can read the same committed value, independently mutate
their temporaries, and then overwrite each other. The last setter wins. A type
stored inside `Stored` should not introduce its own reference-semantic
coordinator merely to work around this Core-level limitation.

Swift also performs the property writeback when a nested mutating method
throws. The value may be logically unchanged, but a non-Equatable `Stored`
still treats that writeback as an assignment and can publish its normal
notifications. For example, `EntityStore.updateOrCreate` guarantees that it
does not replace or insert a dictionary entry when its closure throws; it
cannot guarantee that an enclosing `@GraphStored` property suppresses the
unwinding writeback.

## Why a Generic `_modify` Accessor Is Not the Answer

An earlier `Stored` implementation yielded its value from `_modify` while
holding the node lock. Swift can keep that accessor active for the full
duration of a mutating call, including a mutating `async` method. Code that
accesses the node again during that interval can deadlock. The regression is
covered by `DeadlockTests` and was fixed in
[PR #56](https://github.com/VergeGroup/swift-state-graph/pull/56).

A graph node also must not execute invalidation or user callbacks while holding
its value lock. Consequently, restoring a generic lock-holding `_modify`
accessor is not an acceptable optimization.

`unsafeModify(_:)` remains an intentionally low-level escape hatch. It bypasses
the normal mutation pipeline and does not provide the semantics required by a
general-purpose mutation API.

## Desired Stored-Level API

A future API should provide a synchronous, nonescaping mutation scope owned by
`Stored`, rather than by individual container types. Its design must satisfy
all of the following:

- The mutation closure cannot suspend or escape.
- Normal setters and scoped mutations participate in the same writer
  coordination, so concurrent read-modify-write operations do not lose
  updates.
- The value is mutated without an avoidable getter/writeback copy. A real
  shared copy-on-write buffer may still copy on its first mutation.
- Repeated mutations inside one scope reuse the same mutable value.
- Comparison, graph invalidation, Observation, tracking callbacks, and
  `onDidSet` retain their documented ordering and occur after exclusive value
  access ends.
- No graph or user callback runs while a node lock or writer-coordination lock
  is held.
- Callback-triggered reentrant mutation cannot deadlock.
- Throwing-closure behavior, including whether a failed mutation is published
  or rolled back, is explicit and covered for both value and reference types.
- Reads and computed dependencies continue to observe a coherent documented
  value throughout the mutation.
- Stress tests cover competing setters, scoped mutations, readers, and
  reentrant callbacks.

## Current Guidance

Keep mutable application state, including value-semantic `EntityStore`
instances, in `Stored` or `@GraphStored`. Prefer an operation that performs a
whole batch in one method call when possible. Applications that permit
concurrent mutation of the same property must currently serialize the complete
read-modify-write operation at the owning actor or queue.

This issue concerns in-memory `Stored` mutation. It does not require
`EntityStore` to have reference semantics, and it is not a database transaction
or rollback mechanism for external side effects.
