// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CorrespondanceCore",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "CorrespondanceMatrixClient", targets: ["CorrespondanceMatrixClient"]),
        .library(name: "CorrespondanceCore", targets: ["CorrespondanceCore"]),
        .library(name: "CorrespondanceUI", targets: ["CorrespondanceUI"]),
        .library(name: "CorrespondanceAgentKit", targets: ["CorrespondanceAgentKit"]),
        // Le seul bout d'Objective-C du dépôt : rattraper une exception AppKit,
        // ce que Swift ne sait pas faire. Cf. CorrespondanceExceptionCatcher.h.
        .library(name: "CorrespondanceObjC", targets: ["CorrespondanceObjC"]),
        .executable(name: "correspondance-agent", targets: ["correspondance-agent"]),
        // L'inbox comme outil : un serveur MCP que Claude Desktop ou Zed lancent.
        .executable(name: "correspondance-mcp", targets: ["correspondance-mcp"]),
    ],
    targets: [
        // Le client Matrix REST, Foundation pur : compile sous Linux pour l'agent.
        .target(name: "CorrespondanceMatrixClient"),
        .target(name: "CorrespondanceObjC"),
        .target(name: "CorrespondanceCore", dependencies: ["CorrespondanceMatrixClient"]),
        .target(name: "CorrespondanceUI", dependencies: ["CorrespondanceCore"]),
        // L'agent « cc » : un client Matrix ordinaire qui parle à Claude Code.
        // La logique (déclencheur, plafond, lecture de la sortie) vit dans le kit,
        // testable sans réseau ; l'exécutable ne fait que brancher.
        .target(name: "CorrespondanceAgentKit", dependencies: ["CorrespondanceMatrixClient"]),
        .executableTarget(name: "correspondance-agent", dependencies: ["CorrespondanceAgentKit"]),
        .executableTarget(name: "correspondance-mcp", dependencies: ["CorrespondanceAgentKit", "CorrespondanceCore"]),
        .testTarget(
            name: "CorrespondanceCoreTests",
            dependencies: ["CorrespondanceCore"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(name: "CorrespondanceUITests", dependencies: ["CorrespondanceUI"]),
        .testTarget(name: "CorrespondanceAgentKitTests", dependencies: ["CorrespondanceAgentKit"]),
    ]
)
