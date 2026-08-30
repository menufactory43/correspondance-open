// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CorrespondanceCore",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "CorrespondanceCore", targets: ["CorrespondanceCore"]),
        .library(name: "CorrespondanceUI", targets: ["CorrespondanceUI"]),
    ],
    targets: [
        .target(name: "CorrespondanceCore"),
        .target(name: "CorrespondanceUI", dependencies: ["CorrespondanceCore"]),
        .testTarget(
            name: "CorrespondanceCoreTests",
            dependencies: ["CorrespondanceCore"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(name: "CorrespondanceUITests", dependencies: ["CorrespondanceUI"]),
    ]
)
