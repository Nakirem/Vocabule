import XCTest
@testable import VocabulleCore

/// Vérifie la normalisation contre le contrat partagé avec la chaîne Python.
///
/// # Pourquoi ce test lit un fichier plutôt que d'écrire les cas ici
///
/// La colonne `search_text` du corpus est remplie par le code Python ; la
/// requête de l'utilisateur est normalisée par le code Swift. Si les deux
/// implémentations divergent, rien ne casse : la recherche cesse simplement de
/// trouver. « ephemere » ne trouve plus « éphémère », et aucun test ne le
/// signale puisque chaque côté reste cohérent avec lui-même.
///
/// Les deux lisent donc le **même** fichier de cas (`Tests/Fixtures/`), et
/// `scripts/validate_corpus.py` le fait passer côté Python. Une divergence fait
/// échouer l'un des deux.
final class TextNormalizationTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Case: Decodable {
            let input: String
            let expected: String
        }
        let version: Int
        let rationale: String
        let normalize: [Case]
        let slug: [Case]
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/Core
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // racine du dépôt
            .appendingPathComponent("Tests/Fixtures/normalization.json")
    }

    private func loadFixture() throws -> Fixture {
        let data = try Data(contentsOf: Self.fixtureURL)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    func testNormalizationMatchesTheSharedContract() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.normalize.isEmpty, "Le fichier de référence ne contient aucun cas")

        for testCase in fixture.normalize {
            XCTAssertEqual(
                SearchNormalizer.normalize(testCase.input),
                testCase.expected,
                "normalize(\(testCase.input)) a divergé du contrat partagé : "
                + "la chaîne de production et l'application ne chercheraient plus la même chose"
            )
        }
    }

    func testSlugMatchesTheSharedContract() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.slug.isEmpty)

        for testCase in fixture.slug {
            XCTAssertEqual(
                EntryID.slug(from: testCase.input),
                testCase.expected,
                "slug(\(testCase.input)) a divergé : les identifiants de fiche et les "
                + "liens profonds déjà enregistrés ne correspondraient plus"
            )
        }
    }

    /// Les ligatures ne doivent être décomposées d'aucun côté.
    ///
    /// C'est le cas le plus fragile du contrat : `œ` n'est pas décomposé par
    /// NFD, et `String.folding(.diacriticInsensitive)` le laisse intact. Le
    /// décomposer d'un seul côté ferait diverger les deux implémentations sans
    /// qu'aucun test « normal » ne s'en aperçoive.
    func testLigaturesAreKeptInNormalization() {
        XCTAssertEqual(SearchNormalizer.normalize("nœud"), "nœud")
        XCTAssertEqual(SearchNormalizer.normalize("cœur"), "cœur")
    }

    /// Les identifiants, eux, exigent de l'ASCII : la ligature devient un tiret.
    func testLigaturesBecomeDashesInSlugs() {
        XCTAssertEqual(EntryID.slug(from: "nœud gordien"), "n-ud-gordien")
    }

    func testTermsSplitsAQueryIntoWords() {
        XCTAssertEqual(
            SearchNormalizer.terms(in: "  Victoire à la Pyrrhus "),
            ["victoire", "a", "la", "pyrrhus"]
        )
        XCTAssertEqual(SearchNormalizer.terms(in: "!!!"), [])
        XCTAssertTrue(SearchNormalizer.terms(in: "").isEmpty)
    }
}
