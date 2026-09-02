// swift-tools-version: 6.0
import PackageDescription
import Foundation

// MARK: - Le drapeau du chiffrement
//
// Le chiffrement de bout en bout est un chantier commencé, pas fini (phase 2 du
// spike « un clic »). Il est donc **derrière un drapeau de manifeste** : sans la
// variable d'environnement, ce fichier décrit exactement le paquet d'avant —
// aucune dépendance binaire n'est résolue, aucune cible en plus, et `cc`
// continue de se construire sur Linux, où l'XCFramework n'existe pas.
//
//     swift build                                  → sans chiffrement (par défaut)
//     CORRESPONDANCE_CRYPTO=1 swift build           → avec la machine crypto Rust
//
// Le drapeau au niveau du manifeste, plutôt qu'un `#if` dans le code, parce que
// la dépendance elle-même (150 Mo d'XCFramework, Apple seulement) ne doit pas
// exister quand on n'en veut pas.
let chiffrement = ProcessInfo.processInfo.environment["CORRESPONDANCE_CRYPTO"] == "1"

// matrix-sdk-crypto-ffi 0.17.0 — la machine Olm/Megolm seule, telle que
// matrix-org la publie. Somme du zip relevée le 2 septembre 2026 ; `swift
// package compute-checksum` la recalcule.
let cryptoVersion = "matrix-sdk-crypto-ffi-0.17.0"
let cryptoURL = "https://github.com/matrix-org/matrix-rust-sdk/releases/download/\(cryptoVersion)/MatrixSDKCryptoFFI.zip"
let cryptoChecksum = "7d5e15e072eccb8cf105570bd50ebde9dece60b1bcef007139b4f265f2b0d75a"

let package = Package(
    name: "CorrespondanceCore",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "CorrespondanceMatrixClient", targets: ["CorrespondanceMatrixClient"]),
        .library(name: "CorrespondanceCore", targets: ["CorrespondanceCore"]),
        .library(name: "CorrespondanceUI", targets: ["CorrespondanceUI"]),
        .library(name: "CorrespondanceAgentKit", targets: ["CorrespondanceAgentKit"]),
        .executable(name: "correspondance-agent", targets: ["correspondance-agent"]),
        // L'inbox comme outil : un serveur MCP que Claude Desktop ou Zed lancent.
        .executable(name: "correspondance-mcp", targets: ["correspondance-mcp"]),
    ],
    targets: [
        // Le client Matrix REST, Foundation pur : compile sous Linux pour l'agent.
        .target(name: "CorrespondanceMatrixClient"),
        // Le chiffrement entre ici **par le drapeau seulement** : sans lui,
        // `CorrespondanceCore` ne connaît pas la cible crypto et le `#if
        // canImport` de MatrixChiffrement.swift efface le branchement.
        .target(
            name: "CorrespondanceCore",
            dependencies: ["CorrespondanceMatrixClient"] + (chiffrement ? ["CorrespondanceMatrixCrypto"] : [])
        ),
        .target(name: "CorrespondanceUI", dependencies: ["CorrespondanceCore"]),
        // L'agent « cc » : un client Matrix ordinaire qui parle à Claude Code.
        // La logique (déclencheur, plafond, lecture de la sortie) vit dans le kit,
        // testable sans réseau ; l'exécutable ne fait que brancher.
        .target(name: "CorrespondanceAgentKit", dependencies: ["CorrespondanceMatrixClient"]),
        // `cc` gagne la même machine crypto que l'app **quand le drapeau est
        // levé** : il partage déjà `MatrixClient`, il ne lui manquait que le
        // moteur. Sous Linux, où l'XCFramework n'existe pas, le drapeau reste
        // baissé et l'agent se construit exactement comme avant.
        .executableTarget(
            name: "correspondance-agent",
            dependencies: ["CorrespondanceAgentKit", "CorrespondanceMatrixClient"]
                + (chiffrement ? ["CorrespondanceMatrixCrypto"] : [])
        ),
        .executableTarget(name: "correspondance-mcp", dependencies: ["CorrespondanceAgentKit", "CorrespondanceCore"]),
        .testTarget(
            name: "CorrespondanceCoreTests",
            dependencies: ["CorrespondanceCore"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(name: "CorrespondanceUITests", dependencies: ["CorrespondanceUI"]),
        .testTarget(name: "CorrespondanceAgentKitTests", dependencies: ["CorrespondanceAgentKit"]),
    ] + (chiffrement ? ciblesChiffrement : [])
)

// MARK: - Les cibles qui n'existent que le drapeau levé

var ciblesChiffrement: [Target] {
    [
        // L'XCFramework officiel : trois tranches (macOS universel, iOS, simulateur),
        // des bibliothèques **statiques** — seul le code appelé entre dans le binaire.
        .binaryTarget(name: "MatrixSDKCryptoFFI", url: cryptoURL, checksum: cryptoChecksum),
        // Les liaisons uniffi engendrées, telles quelles dans le zip amont : elles
        // vivent dans le dépôt parce que le zip ne se laisse pas consommer comme un
        // paquet SPM (il n'a pas de Package.swift), et parce qu'un binaire sans ses
        // liaisons ne sert à rien.
        .target(
            name: "MatrixSDKCrypto",
            dependencies: ["MatrixSDKCryptoFFI"],
            exclude: ["LICENSE.txt"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Notre adaptateur : il implémente `MatrixCryptoEngine` du client Matrix.
        .target(name: "CorrespondanceMatrixCrypto", dependencies: ["CorrespondanceMatrixClient", "MatrixSDKCrypto"]),
        .testTarget(name: "CorrespondanceMatrixCryptoTests", dependencies: ["CorrespondanceMatrixCrypto"]),
        // Le banc de preuve de la phase 2 : le vrai client, le vrai moteur,
        // deux appareils du même compte. Il ne part pas dans l'app.
        .executableTarget(name: "preuve-chiffrement", dependencies: ["CorrespondanceMatrixCrypto"]),
    ]
}
