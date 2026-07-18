# UserDefaults

Persist graph-aware values by composing UserDefaults synchronization with an
in-memory ``StateGraph/Stored`` node.

## Overview

``StateGraph/Stored`` is the mutation primitive of StateGraph and always owns its
value in memory. Persistence is modeled as a separate owner rather than as a
replaceable storage backend. ``StateGraph/GraphUserDefault`` follows that design:
it synchronizes one UserDefaults key and delegates graph behavior to an internal
`Stored<Value>`.

This keeps graph dependency tracking independent from Foundation lifecycle and
synchronization concerns.

## Basic Usage

Declare a default value and a UserDefaults key:

```swift
final class Settings {
  @GraphUserDefault("theme")
  var theme: String = "light"
}
```

The wrapped property reads and writes UserDefaults. The projected value is the
reference-identity synchronization handle:

```swift
let settings = Settings()

settings.theme = "dark"
let theme: GraphUserDefault<String> = settings.$theme
theme.wrappedValue = "system"
```

The projected handle can be retained independently from `Settings`. It keeps
UserDefaults observation active, and its writes use the same persistence path
as assigning `settings.theme`.

Local writes publish the corresponding internal `Stored` change synchronously.
Changes observed through `UserDefaults.didChangeNotification` also update the
same node, while duplicate notifications for an unchanged value are ignored.

## Graph Dependencies

Capture the projected node just as you would capture a projected `@GraphStored`
property:

```swift
final class Settings {
  @GraphUserDefault("theme")
  var theme: String = "light"

  @GraphComputed
  var isDarkMode: Bool

  init() {
    $isDarkMode = .init { [$theme] _ in
      $theme.wrappedValue == "dark"
    }
  }
}
```

`$theme` has type `GraphUserDefault<String>`. Reading its `wrappedValue`
delegates to the same in-memory `Stored` primitive used everywhere else in the
graph, so dependency tracking remains unchanged.

## Custom Store

Use `store:` to inject a UserDefaults instance. This is useful for app groups,
tests, and model-level dependency injection:

```swift
final class Settings {
  @GraphUserDefault var theme: String

  init(store: UserDefaults) {
    _theme = GraphUserDefault(
      wrappedValue: "light",
      "theme",
      store: store
    )
  }
}
```

## Named Suites

Use `suiteName:` when the suite is known at the declaration site:

```swift
final class SharedSettings {
  @GraphUserDefault("theme", suiteName: "group.com.example.app")
  var theme: String = "light"
}
```

The initializer fails fast if Foundation cannot create the requested suite. It
does not silently fall back to `UserDefaults.standard`.

## Supported Values

StateGraph provides ``StateGraph/UserDefaultsStorable`` conformances for these
Foundation property-list values:

- `Bool`
- `Int`
- `Float`
- `Double`
- `String`
- `Data`
- `Date`
- `URL`
- `Optional` when its wrapped value conforms to `UserDefaultsStorable`

Codable values can adopt the protocol and use its JSON-based default
implementation:

```swift
struct EditorPreferences: Codable, Equatable, Sendable, UserDefaultsStorable {
  var lineNumbersEnabled: Bool
}

final class Settings {
  @GraphUserDefault("editorPreferences")
  var editorPreferences = EditorPreferences(lineNumbersEnabled: true)
}
```

For a custom representation, implement
`UserDefaultsStorable._getValue(from:forKey:defaultValue:)` and
`UserDefaultsStorable._setValue(to:forKey:)` directly.

## Ownership

`GraphUserDefault` is a reference type and its projection returns the same
instance. That identity owns the observer and internal `Stored` node, and
removes the observer after its final owner releases it. An in-flight
notification keeps the instance alive until its callback finishes; callbacks
never publish graph changes while the UserDefaults access lock or the `Stored`
node lock is held.
