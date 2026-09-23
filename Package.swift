// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "oab-mc-agent",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "oab-mc-agent", targets: ["oab-mc-agent"]),
        .library(name: "MacAgentCore", targets: ["MacAgentCore"]),
    ],
    targets: [
        // Everything testable: JSON-RPC, MCP dispatch, HTTP/1.1 parsing, auth, tools.
        .target(
            name: "MacAgentCore",
            path: "Sources/MacAgentCore",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Network"),
            ]
        ),
        // Thin CLI: flag parsing + wiring. No logic worth testing lives here.
        .executableTarget(
            name: "oab-mc-agent",
            dependencies: ["MacAgentCore"],
            path: "Sources/oab-mc-agent"
        ),
        .testTarget(
            name: "MacAgentCoreTests",
            dependencies: ["MacAgentCore"],
            path: "Tests/MacAgentCoreTests"
        ),
    ]
)
