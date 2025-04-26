// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import PackageDescription

let package = Package(
  name: "swift-state-graph",
  platforms: [.macOS(.v13), .iOS(.v17), .tvOS(.v13), .watchOS(.v6), .macCatalyst(.v13)],
  products: [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
      name: "StateGraph",
      targets: ["StateGraph"])
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"602.0.0"),
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
    .testTarget(
      name: "StateGraphTests",
      dependencies: ["StateGraph"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
