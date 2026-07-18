// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Tinker",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "TinkerBar", targets: ["TinkerBar"]),
    ],
    targets: [
        .executableTarget(
            name: "TinkerBar",
            exclude: [
                "Resources/AppIcon.icns",
                "Resources/AppIcon.png",
            ],
            resources: [
                .process("Resources/BuiltinTasks"),
            ]
        ),
        .testTarget(
            name: "TinkerBarTests",
            dependencies: ["TinkerBar"]
        ),
    ]
)
