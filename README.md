# Swift State Graph

## Overview

```swift
final class MyObject {
  @GraphStored
  var count: Int = 0
}
```

```swift
struct MyView {
  let object: MyObject

  var body: some View {
    VStack {
      Text("\(object.count)")
      Button("Increment") {
        object.count += 1
      }
    }
  }
}
```

## Core Concept

There are 2 primitive types.

- Stored value node
- Computed value node

Computed value nodes depend on other nodes.

```swift
let stored = Stored(wrappedValue: 10)

let computed = Computed(wrappedValue: 0) { _ in stored.wrappedValue * 2 }

// computed.wrappedValue => 20

stored.wrappedValue = 20

// computed.wrappedValue => 40
```

## What's the difference from using `Observable` protocol object

