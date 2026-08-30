// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import PackageDescription

let package = Package(
  name: "swift-state-graph",
  platforms: [
    .macOS(
      .v14
    ),
    .iOS(.v17),
    .tvOS(.v17),
    .watchOS(.v10),
  ],
  products: [
    // StateGraph owns process-wide runtime state, so separate framework consumers
    // must resolve one shared binary instead of embedding independent copies.
    .library(
      name: "StateGraph",
      type: .dynamic,
      targets: ["StateGraph"]
    ),
    // Normalization is an independent module. Keeping it dynamic preserves its
    // public Swift type identity when several frameworks consume it.
    .library(
      name: "StateGraphNormalization",
      type: .dynamic,
      targets: ["StateGraphNormalization"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/VergeGroup/swift-typed-identifier.git", from: "2.0.4"),
    .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"605.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-macro-testing.git", from: "0.6.5"),
  ],
  targets: [
    .macro(
      name: "StateGraphMacro",
      dependencies: [
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
      ]
    ),
    .macro(
      name: "StateGraphNormalizationMacro",
      dependencies: [
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
      ]
    ),
    .target(
      name: "StateGraph",
      dependencies: [
        "StateGraphMacro"
      ]
    ),
    .target(
      name: "StateGraphNormalization",
      dependencies: [
        "StateGraphNormalizationMacro",
        .product(name: "TypedIdentifier", package: "swift-typed-identifier")
      ]
    ),
    .testTarget(
      name: "StateGraphMacroTests",
      dependencies: [
        "StateGraphMacro",
        .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
        .product(name: "MacroTesting", package: "swift-macro-testing"),
      ]
    ),
    .testTarget(
      name: "StateGraphNormalizationMacroTests",
      dependencies: [
        "StateGraphNormalizationMacro",
        .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
        .product(name: "MacroTesting", package: "swift-macro-testing"),
      ]
    ),
    .testTarget(
      name: "StateGraphTests",
      dependencies: ["StateGraph"]
    ),
    .testTarget(
      name: "StateGraphNormalizationTests",
      dependencies: [
        "StateGraph",
        "StateGraphNormalization"
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
