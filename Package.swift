// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Howmuchusage",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"]),
        .library(name: "UsageProviders", targets: ["UsageProviders"]),
        .executable(name: "howmuchusage-probe", targets: ["HowmuchusageProbe"]),
        .executable(name: "Howmuchusage", targets: ["Howmuchusage"])
    ],
    targets: [
        // Foundation-only models, parsers, freshness and poll policy.
        .target(name: "UsageCore"),
        // Live connections: codex app-server, Claude OAuth usage, local sources.
        .target(
            name: "UsageProviders",
            dependencies: ["UsageCore"]
        ),
        .executableTarget(
            name: "HowmuchusageProbe",
            dependencies: ["UsageCore", "UsageProviders"]
        ),
        .executableTarget(
            name: "Howmuchusage",
            dependencies: ["UsageCore", "UsageProviders"]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "UsageProvidersTests",
            dependencies: ["UsageCore", "UsageProviders"],
            resources: [.copy("Fixtures")]
        )
    ]
)
