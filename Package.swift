// swift-tools-version: 5.9
import PackageDescription

/// Paquet de logique pure de Vocabulle.
///
/// Il ne décrit **pas** une bibliothèque livrée : il existe pour que la logique
/// métier — créneaux horaires, sélection déterministe, état partagé, accès au
/// corpus — soit compilable et testable sur macOS, sans simulateur ni iPhone.
///
/// Les mêmes fichiers sont compilés par le projet Xcode : la cible ci-dessous
/// pointe directement sur `Core/`, qui est un sous-dossier des sources de
/// l'application. Il n'y a donc pas de copie à maintenir, et `swift test` ne
/// peut pas passer sur un code différent de celui qui part dans l'IPA.
let package = Package(
    name: "VocabulleCore",
    defaultLocalization: "fr",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "VocabulleCore", targets: ["VocabulleCore"])
    ],
    targets: [
        .target(
            name: "VocabulleCore",
            path: "Core",
            // SQLite du système : aucune dépendance externe, donc rien à
            // résoudre au moment du build et aucun risque de rupture
            // d'approvisionnement.
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "VocabulleCoreTests",
            dependencies: ["VocabulleCore"],
            path: "Tests/Core"
        )
    ]
)
