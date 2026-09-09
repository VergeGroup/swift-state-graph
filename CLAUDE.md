# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Building and Testing
```bash
# Build the package
swift build

# Run all tests
swift test

# Run specific test file or test
swift test --filter StateGraphTests.NodeObserveTests

# Build for release
swift build -c release

# Clean build artifacts
swift package clean

# Generate the iOS development app project
mise install
mise exec -- tuist install
mise exec -- tuist generate --no-open

# Build the iOS development app
xcodebuild \
  -project Development.xcodeproj \
  -scheme Development \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

### Package Management
```bash
# Update dependencies
swift package update

# Resolve dependencies
swift package resolve

# Install or update dependencies declared by Package.swift
mise exec -- tuist install

# Regenerate the iOS development app after changing Project.swift
mise exec -- tuist generate --no-open
```

## Architecture Overview

Swift State Graph is a reactive state management library that uses a Directed Acyclic Graph (DAG) to manage data flow and dependencies. The architecture consists of:

### Core Components

1. **Node System** - The foundation of the reactive graph:
   - `Node<Value>`: Type-safe node protocol for storing and computing values
   - `Stored`: Mutable nodes that serve as sources of truth
   - `Computed`: Read-only nodes that derive values from other nodes
   - `Edge`: Represents dependencies between nodes with automatic cleanup

2. **Macro System** - Swift macros for cleaner syntax:
   - `@GraphStored`: Property wrapper for stored values
   - `@GraphComputed`: Macro for cached computed property bodies (Swift 6.4)
   - `@GraphComputedNode`: Macro for explicitly initialized computed nodes
   - `@GraphIgnored`: Marks properties to be ignored by observation
   - `@GraphView`: Generates view logic for state management

3. **Storage Abstraction** - Flexible backing storage:
   - `InMemoryStorage`: Default volatile storage
   - `UserDefaultsStorage`: Persistent storage backed by UserDefaults
   - Protocol-based design allows custom storage implementations

4. **Integration Points**:
   - **SwiftUI**: `GraphObject` protocol for Environment propagation, binding support
   - **UIKit**: `withGraphTracking` for reactive updates in UIKit views
   - **Observable**: Compatible with Swift's Observable protocol (iOS 17+)

### Key Design Principles

- **Automatic Dependency Tracking**: Nodes automatically track which other nodes they depend on
- **Lazy Evaluation**: Computed values only recalculate when accessed after dependencies change
- **Thread Safety**: Uses `NSRecursiveLock` for concurrent access protection
- **Memory Management**: Weak references and automatic edge cleanup prevent retain cycles

### Module Structure

- `StateGraph`: Core reactive graph implementation
- `StateGraphMacro`: Swift macro implementations
- `StateGraphNormalization`: Data normalization for relational data management

The library emphasizes declarative state management with minimal boilerplate while maintaining type safety and performance.
