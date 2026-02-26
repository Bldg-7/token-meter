// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "token-meter",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "TokenMeterApp", targets: ["TokenMeterApp"]),
        .library(name: "TokenMeterCore", targets: ["TokenMeterCore"]),
        .library(name: "TokenMeterTrack1", targets: ["TokenMeterTrack1"]),
        .library(name: "TokenMeterTrack2", targets: ["TokenMeterTrack2"]),
        .library(name: "TokenMeterToolDiscovery", targets: ["TokenMeterToolDiscovery"]),
        .library(name: "TokenMeterLocalization", targets: ["TokenMeterLocalization"]),
    ],
    targets: [
        .executableTarget(
            name: "TokenMeterApp",
            dependencies: [
                "TokenMeterCore",
                "TokenMeterLocalization",
            ]
        ),
        .target(name: "TokenMeterCore"),
        .target(name: "TokenMeterTrack1", dependencies: ["TokenMeterCore"]),
        .target(name: "TokenMeterTrack2", dependencies: ["TokenMeterCore"]),
        .target(name: "TokenMeterToolDiscovery", dependencies: ["TokenMeterCore"]),
        .target(
            name: "TokenMeterLocalization",
            dependencies: ["TokenMeterCore"],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(name: "TokenMeterCoreTests", dependencies: ["TokenMeterCore"]),
    ]
)
