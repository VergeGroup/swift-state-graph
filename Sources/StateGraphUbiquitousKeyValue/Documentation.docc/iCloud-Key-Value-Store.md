# iCloud Key-Value Store

Synchronize small graph-aware values across a person's devices by composing
iCloud key-value storage with an in-memory `Stored` node.

## Overview

``StateGraphUbiquitousKeyValue/GraphUbiquitousKeyValue`` is the iCloud
counterpart to `GraphUserDefault`. It owns one `Stored<Value>` and
synchronizes that snapshot with one key in
[`NSUbiquitousKeyValueStore.default`](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore/default).

Use it for small settings, configuration, and app state that change
infrequently. It is not appropriate for sensitive information, documents,
large values, or high-frequency state.

## Configure the App Target

Enable iCloud key-value storage for every app target that uses the wrapper. The
signed app needs the `com.apple.developer.ubiquity-kvstore-identifier`
entitlement. Targets that should share a store must use the same key-value store
identifier.

The Swift package itself doesn't add or validate this entitlement. A missing or
incorrect entitlement prevents the host app from synchronizing with iCloud.

## Basic Usage

Declare a default value and an iCloud key-value store key:

```swift
import StateGraphUbiquitousKeyValue

final class ReadingState {
  @GraphUbiquitousKeyValue("currentPage")
  var currentPage = 1
}
```

The wrapped property reads the in-memory graph snapshot and writes through to
the shared iCloud key-value store. The projected value is the same
reference-identity synchronization handle:

```swift
let state = ReadingState()
let currentPage: GraphUbiquitousKeyValue<Int> = state.$currentPage

currentPage.wrappedValue = 42
```

Retaining the projected value keeps its store subscription active. Its reads
participate in graph dependency tracking in the same way as a projected
`@GraphStored` value.

## Synchronization Semantics

The first live wrapper installs the external-change observer and then calls
`synchronize()` once for the process-wide coordinator. Local assignments update
the backing store and graph snapshot synchronously. Other live wrappers for the
same key are also refreshed without waiting for an iCloud notification.

Treat the wrapper or its projected value as the exclusive in-process writer for
a managed key. Foundation's external-change notification reports incoming
iCloud data, not direct writes made elsewhere in the same process, so a raw
`NSUbiquitousKeyValueStore.default.set` call can't refresh an existing graph
snapshot.

Changes arriving from iCloud update the relevant graph snapshots. An Apple
account change refreshes all live keys because values from the previous account
may have disappeared. Duplicate notifications that decode to the current value
don't publish another graph change.

Device-to-device propagation remains asynchronous. `synchronize()` doesn't
force an upload, and assigning a value doesn't mean another device has already
received it. Initial iCloud reconciliation can also replace a value written
during startup.

`GraphUbiquitousKeyValue` intentionally doesn't mirror values into
`UserDefaults`. If a value must have an independent, durable local source of
truth when iCloud is unavailable, own that local persistence separately and use
the iCloud store as a synchronization channel.

## Supported Values

``StateGraphUbiquitousKeyValue/UbiquitousKeyValueStorable`` has built-in
conformances for:

- `Bool`
- `Int` and `Int64`
- `Float` and `Double`
- `String`
- `Data`
- `Date`
- `Array` when its elements conform
- `Dictionary<String, Value>` when its values conform
- `Optional` when its wrapped value conforms

Assigning an optional `nil` removes the key. A missing or invalid value exposes
the default declared by the property, so declare an optional default of `nil`
when removal should read back as `nil`.

A Codable value can adopt the protocol and use its JSON `Data` representation:

```swift
struct ReaderPreferences:
  Codable,
  Equatable,
  Sendable,
  UbiquitousKeyValueStorable
{
  var usesSerifFont: Bool
}

final class ReadingState {
  @GraphUbiquitousKeyValue("readerPreferences")
  var preferences = ReaderPreferences(usesSerifFont: true)
}
```

Prefer the native property-list conformances for simple values. Codable data
counts against the same iCloud storage quota.

## Platform Limits

The host app is responsible for keeping values within
[the limits of `NSUbiquitousKeyValueStore`](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore):

- At most 1,024 keys.
- At most 1 MB across all values.
- At most 1 MB for any one value.
- At most 128 UTF-16 characters in a key.

Foundation raises an exception for an overlong key. A quota violation is a
store-wide operational failure and isn't surfaced as a successful value change
by this wrapper.

Do not store personal or sensitive information here. Apple documents that the
on-disk representation isn't encrypted; use Keychain for secrets.
