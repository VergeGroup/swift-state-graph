import ProjectDescription

let developmentTarget: Target = .target(
  name: "Development",
  destinations: .iOS,
  product: .app,
  bundleId: "app.muukii.dev-swift-state-graph",
  deploymentTargets: .iOS("17.0"),
  infoPlist: .dictionary([
    "CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)",
    "CFBundleExecutable": "$(EXECUTABLE_NAME)",
    "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "$(PRODUCT_NAME)",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "LSRequiresIPhoneOS": true,
    "UIApplicationSceneManifest": [
      "UIApplicationSupportsMultipleScenes": true,
      "UISceneConfigurations": [:],
    ],
    "UIApplicationSupportsIndirectInputEvents": true,
    "UILaunchScreen": [:],
    "UISupportedInterfaceOrientations~ipad": [
      "UIInterfaceOrientationPortrait",
      "UIInterfaceOrientationPortraitUpsideDown",
      "UIInterfaceOrientationLandscapeLeft",
      "UIInterfaceOrientationLandscapeRight",
    ],
    "UISupportedInterfaceOrientations~iphone": [
      "UIInterfaceOrientationPortrait",
      "UIInterfaceOrientationLandscapeLeft",
      "UIInterfaceOrientationLandscapeRight",
    ],
  ]),
  buildableFolders: ["Development"],
  dependencies: [
    .package(product: "StateGraph"),
    .package(product: "StateGraphNormalization"),
    .package(product: "StorybookKit"),
  ],
  settings: .settings(
    base: [
      "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
      "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
      "CURRENT_PROJECT_VERSION": "1",
      "DEVELOPMENT_ASSET_PATHS": "\"Development/Preview Content\"",
      "ENABLE_PREVIEWS": "YES",
      "MARKETING_VERSION": "1.0",
      "SWIFT_EMIT_LOC_STRINGS": "YES",
      "SWIFT_VERSION": "6.0",
      "TARGETED_DEVICE_FAMILY": "1,2",
    ]
  )
)

let project = Project(
  name: "Development",
  options: .options(automaticSchemesOptions: .disabled),
  packages: [
    // The development app exercises the products built by this repository.
    .local(path: "."),
    .remote(
      url: "https://github.com/eure/swift-storybook",
      requirement: .upToNextMajor(from: "3.1.0")
    ),
  ],
  targets: [
    developmentTarget
  ],
  schemes: [
    .scheme(
      name: "Development",
      shared: true,
      buildAction: .buildAction(targets: ["Development"]),
      testAction: .targets([]),
      runAction: .runAction(
        configuration: .debug,
        executable: .executable("Development")
      ),
      archiveAction: .archiveAction(configuration: .release),
      profileAction: .profileAction(
        configuration: .release,
        executable: .executable("Development")
      ),
      analyzeAction: .analyzeAction(configuration: .debug)
    )
  ]
)
