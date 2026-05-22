// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Howmuchusage",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CodexUsageCore",
            targets: ["CodexUsageCore"]
        ),
        .executable(
            name: "howmuchusage-probe",
            targets: ["HowmuchusageProbe"]
        ),
        .executable(
            name: "HowmuchusageMenuBar",
            targets: ["HowmuchusageMenuBar"]
        )
    ],
    targets: [
        .target(name: "CodexUsageCore"),
        .executableTarget(
            name: "HowmuchusageProbe",
            dependencies: ["CodexUsageCore"]
        ),
        .executableTarget(
            name: "HowmuchusageMenuBar",
            dependencies: ["CodexUsageCore"]
        ),
        .testTarget(
            name: "CodexUsageCoreTests",
            dependencies: ["CodexUsageCore"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)

