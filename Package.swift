// swift-tools-version: 6.0
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
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
      name: "StateGraph",
      targets: ["StateGraph"]
    ),
    .library(
      name: "StateGraphNormalization",
      targets: ["StateGraphNormalization"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/VergeGroup/swift-typed-identifier.git", from: "2.0.4"),
    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-macro-testing.git", from: "0.5.2"),
  ],
  targets: [
    .macro(
      name: "StateGraphMacro",
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
        "StateGraph",
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
