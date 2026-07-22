// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BeipMU",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BeipCore", targets: ["BeipCore"]),
        .library(name: "BeipProtocols", targets: ["BeipProtocols"]),
        .library(name: "BeipPersistence", targets: ["BeipPersistence"]),
        .library(name: "BeipAutomation", targets: ["BeipAutomation"]),
        .library(name: "BeipUI", targets: ["BeipUI"]),
        .library(name: "BeipScriptRuntime", targets: ["BeipScriptRuntime"]),
        .executable(name: "BeipWorkspaceBenchmark", targets: ["BeipWorkspaceBenchmark"]),
    ],
    targets: [
        .target(name: "BeipCore"),
        .target(
            name: "BeipProtocols",
            dependencies: ["BeipCore"],
            linkerSettings: [.linkedFramework("Network"), .linkedFramework("Security")]
        ),
        .target(name: "BeipPersistence", dependencies: ["BeipCore", "BeipAutomation"]),
        .target(name: "BeipAutomation", dependencies: ["BeipCore"]),
        .target(
            name: "BeipScriptRuntime",
            dependencies: ["BeipCore"],
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        .target(
            name: "BeipUI",
            dependencies: ["BeipCore", "BeipProtocols", "BeipPersistence", "BeipAutomation", "BeipScriptRuntime"],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("WebKit"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .target(
            name: "BeipTestSupport",
            dependencies: ["BeipCore"],
            path: "Tests/Support",
            linkerSettings: [.linkedFramework("Network"), .linkedFramework("Security")]
        ),
        .executableTarget(
            name: "BeipWorkspaceBenchmark",
            dependencies: ["BeipCore"],
            path: "Benchmarks/WorkspaceBenchmark"
        ),
        .testTarget(name: "BeipCoreTests", dependencies: ["BeipCore"]),
        .testTarget(name: "BeipProtocolsTests", dependencies: ["BeipProtocols", "BeipCore", "BeipTestSupport"]),
        .testTarget(name: "BeipPersistenceTests", dependencies: ["BeipPersistence", "BeipCore"]),
        .testTarget(name: "BeipAutomationTests", dependencies: ["BeipAutomation", "BeipCore"]),
        .testTarget(name: "BeipScriptRuntimeTests", dependencies: ["BeipScriptRuntime"]),
        .testTarget(name: "BeipUITests", dependencies: ["BeipUI"]),
    ]
)
