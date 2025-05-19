import ProjectDescription

let project = Project(
    name: "IMDBClient",
    organizationName: "swift-state-graph-demo",
    options: .options(
        automaticSchemesOptions: .disabled,
        disableBundleAccessors: false,
        disableSynthesizedResourceAccessors: false
    ),
    packages: [
        .local(path: .relativeToRoot("../swift-state-graph"))
    ],
    settings: .settings(
        base: [:],
        debug: [:],
        release: [:],
        defaultSettings: .recommended
    ),
    targets: [
        .target(
            name: "IMDBClient",
            platform: .iOS,
            product: .app,
            bundleId: "com.swift-state-graph-demo.imdbclient",
            deploymentTarget: .iOS(targetVersion: "16.0", devices: [.iPhone, .iPad]),
            sources: ["Sources/**"],
            resources: ["Resources/**"],
            dependencies: [
                .package(product: "StateGraph"),
                .package(product: "StateGraphNormalization")
            ]
        )
    ]
)
