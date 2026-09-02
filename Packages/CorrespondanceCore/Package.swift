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

// MARK: - Le même chiffrement, sous Linux
//
// L'artefact amont `MatrixSDKCryptoFFI.zip` est un XCFramework de tranches
// Apple : sous Linux il n'y a rien à télécharger, et son `Sources/` ne contient
// même pas la carte de modules. Il faut donc **construire** la bibliothèque
// (`cargo` + `zig cc`, cf. `infra/relais/crypto-linux.sh`) et pointer ce
// manifeste sur le dossier qui la contient :
//
//     CORRESPONDANCE_CRYPTO=1 \
//     CORRESPONDANCE_CRYPTO_LINUX=~/.correspondance-unclic/crypto-linux/x86_64 \
//     swift build --swift-sdk x86_64-swift-linux-musl --product correspondance-agent
//
// Les en-têtes engendrés, eux, vivent dans le dépôt
// (`Sources/MatrixSDKCryptoFFILinux/include/`) : ce sont du texte, ils ne
// changent qu'avec la version épinglée, et un `.a` sans eux ne sert à rien.
// Le chemin est une variable et non une constante parce qu'un `.a` de 166 Mio
// n'a rien à faire dans un dépôt Git.
let chiffrementLinux = ProcessInfo.processInfo.environment["CORRESPONDANCE_CRYPTO_LINUX"]
  .map { ($0 as NSString).expandingTildeInPath }

// matrix-sdk-crypto-ffi 0.17.0 — la machine Olm/Megolm seule, telle que
// matrix-org la publie. Somme du zip relevée le 2 septembre 2026 ; `swift
// package compute-checksum` la recalcule.
let cryptoVersion = "matrix-sdk-crypto-ffi-0.17.0"
let cryptoURL = "https://github.com/matrix-org/matrix-rust-sdk/releases/download/\(cryptoVersion)/MatrixSDKCryptoFFI.zip"
let cryptoChecksum = "7d5e15e072eccb8cf105570bd50ebde9dece60b1bcef007139b4f265f2b0d75a"

// swift-crypto n'entre que pour la construction Linux : sur Apple, le coffre du
// chiffrement passe par CryptoKit, qui est dans le système. Une dépendance de
// moins à résoudre pour l'app, pour l'iPhone et pour la CI.
//
// Les deux constantes sont typées à la main : écrites en ternaire à l'endroit
// où elles servent, le vérificateur de types du manifeste abandonne
// (« unable to type-check this expression in reasonable time »).
let dependancesDuPaquet: [Package.Dependency] =
    chiffrementLinux == nil
    ? []
    : [.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1")]

let cryptoKitDeRemplacement: [Target.Dependency] =
    chiffrementLinux == nil ? [] : [.product(name: "Crypto", package: "swift-crypto")]

/// La machine crypto, telle que les autres cibles la nomment.
let moteurCrypto: [Target.Dependency] = chiffrement ? ["CorrespondanceMatrixCrypto"] : []

/// Le nom de la cible qui porte la bibliothèque : l'XCFramework Apple, ou la
/// cible C qui porte les en-têtes quand on croise vers Linux.
let nomDeLaBibliotheque: String =
    chiffrementLinux == nil ? "MatrixSDKCryptoFFI" : "MatrixSDKCryptoFFILinux"

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
    dependencies: dependancesDuPaquet,
    targets: ciblesDuPaquet
)

// MARK: - Les cibles
//
// Sorties de l'appel à `Package(...)` et typées à la main : le vérificateur de
// types du manifeste abandonne sur un littéral de cette taille dès qu'une
// concaténation conditionnelle s'y ajoute — « unable to type-check this
// expression in reasonable time », sur la ligne du `Package(`, ce qui ne dit
// rien de la cible fautive.
//
// `var` calculée et non `let` : dans un manifeste, le code de plus haut niveau
// s'exécute dans l'ordre du fichier, et un `let` déclaré **après**
// `let package = Package(...)` serait lu avant d'être initialisé — le manifeste
// se compile, ne produit aucun JSON, et SwiftPM dit seulement « Missing or
// empty JSON output ».
var ciblesDuPaquet: [Target] {
    // Le littéral et la concaténation sont séparés : écrits d'un seul
    // souffle, le vérificateur de types du manifeste abandonne
    // (« unable to type-check this expression in reasonable time ») et
    // désigne la ligne du crochet, qui ne dit rien de la cause.
    var cibles: [Target] = [
        // Le client Matrix REST, Foundation pur : compile sous Linux pour l'agent.
        .target(name: "CorrespondanceMatrixClient"),
        // Le chiffrement entre ici **par le drapeau seulement** : sans lui,
        // `CorrespondanceCore` ne connaît pas la cible crypto et le `#if
        // canImport` de MatrixChiffrement.swift efface le branchement.
        .target(
            name: "CorrespondanceCore",
            dependencies: ["CorrespondanceMatrixClient"] + moteurCrypto
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
                + moteurCrypto
        ),
        .executableTarget(name: "correspondance-mcp", dependencies: ["CorrespondanceAgentKit", "CorrespondanceCore"]),
        .testTarget(
            name: "CorrespondanceCoreTests",
            dependencies: ["CorrespondanceCore"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(name: "CorrespondanceUITests", dependencies: ["CorrespondanceUI"]),
        .testTarget(name: "CorrespondanceAgentKitTests", dependencies: ["CorrespondanceAgentKit"]),
]
    if chiffrement { cibles += ciblesChiffrement }
    return cibles
}


// MARK: - Les cibles qui n'existent que le drapeau levé

var ciblesChiffrement: [Target] {
    [
        // La bibliothèque elle-même : l'XCFramework officiel sur Apple, la
        // nôtre — construite pour musl depuis ce Mac — sous Linux.
        cibleDeLaBibliotheque,
        // Les liaisons uniffi engendrées, telles quelles dans le zip amont : elles
        // vivent dans le dépôt parce que le zip ne se laisse pas consommer comme un
        // paquet SPM (il n'a pas de Package.swift), et parce qu'un binaire sans ses
        // liaisons ne sert à rien.
        .target(
            name: "MatrixSDKCrypto",
            dependencies: [.target(name: nomDeLaBibliotheque)],
            exclude: ["LICENSE.txt"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Notre adaptateur : il implémente `MatrixCryptoEngine` du client Matrix.
        .target(
            name: "CorrespondanceMatrixCrypto",
            dependencies: ["CorrespondanceMatrixClient", "MatrixSDKCrypto"] + cryptoKitDeRemplacement
        ),
        .testTarget(name: "CorrespondanceMatrixCryptoTests", dependencies: ["CorrespondanceMatrixCrypto"]),
        // Le banc de preuve de la phase 2 : le vrai client, le vrai moteur,
        // deux appareils du même compte. Il ne part pas dans l'app.
        .executableTarget(name: "preuve-chiffrement", dependencies: ["CorrespondanceMatrixCrypto"]),
    ]
}

/// Sur Apple, l'XCFramework amont ; sous Linux, une cible C qui ne porte que
/// les en-têtes engendrés et sa carte de modules — le `.a`, lui, entre par
/// l'éditeur de liens.
///
/// La carte de modules du dépôt est celle de l'XCFramework **moins ses trois
/// `use "Darwin"`** : sous Linux ce module n'existe pas, et clang refuse la
/// carte entière pour cette seule ligne.
var cibleDeLaBibliotheque: Target {
    guard let chiffrementLinux else {
        // Trois tranches (macOS universel, iOS, simulateur), des bibliothèques
        // **statiques** — seul le code appelé entre dans le binaire.
        return .binaryTarget(name: "MatrixSDKCryptoFFI", url: cryptoURL, checksum: cryptoChecksum)
    }
    return .target(
        name: "MatrixSDKCryptoFFILinux",
        linkerSettings: [
            .unsafeFlags(["-L\(chiffrementLinux)", "-lmatrix_sdk_crypto_ffi"])
        ]
    )
}
