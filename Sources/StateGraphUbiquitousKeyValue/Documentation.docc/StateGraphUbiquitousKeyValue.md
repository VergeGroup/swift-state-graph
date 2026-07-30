# ``StateGraphUbiquitousKeyValue``

Synchronize small graph-aware values through iCloud key-value storage.

## Overview

StateGraphUbiquitousKeyValue is an optional extension module for the
`StateGraph` module. It composes an in-memory graph node with
`NSUbiquitousKeyValueStore` without adding iCloud synchronization to the core
StateGraph module.

Import `StateGraphUbiquitousKeyValue` in targets that need this integration.
The module re-exports StateGraph so graph primitives remain available from the
same import.

## Topics

### Getting Started

- <doc:iCloud-Key-Value-Store>

### Synchronized Values

- ``GraphUbiquitousKeyValue``
- ``UbiquitousKeyValueStorable``
