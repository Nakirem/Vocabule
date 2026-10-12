import XCTest
@testable import VocabulleCore

/// Tests du magasin de corpus, exécutés **sur le corpus réellement livré**.
///
/// # Pourquoi tester la vraie base et non une base fabriquée
///
/// Une base fabriquée par le test serait écrite par la même personne que le
/// code qui la lit : elle validerait ses propres hypothèses. Le corpus livré,
/// lui, est produit par une chaîne Python indépendante, et c'est précisément
/// là que les contrats se rompent.
///
/// Ce test attrape une panne qui ne se voit nulle part ailleurs : pendant le
/// développement, les colonnes JSON contenaient `target_term` là où
/// `JSONDecoder` attendait `targetTerm`. La chaîne de production réussissait,
/// la base était valide — et l'application aurait affiché « corpus
/// inaccessible » sans que rien n'explique pourquoi. Décoder **chaque** fiche
/// est le seul contrôle qui l'attrape.
final class SQLiteCorpusStoreTests: XCTestCase {

    private static var databaseURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/Core
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // racine du dépôt
            .appendingPathComponent("Resources/vocabulle-corpus.sqlite")
    }

    private func makeStore() throws -> SQLiteCorpusStore {
        try SQLiteCorpusStore(url: Self.databaseURL)
    }

    private func allIdentifiers(_ store: SQLiteCorpusStore) throws -> [EntryID] {
        var result: [EntryID] = []
        for category in EntryCategory.allCases {
            result.append(contentsOf: try store.candidateIDs(category: category, limit: Int.max))
        }
        return result
    }

    // MARK: - Ouverture

    func testMissingDatabaseIsReportedAsSuch() {
        let missing = URL(fileURLWithPath: "/tmp/vocabulle-inexistant-\(UUID().uuidString).sqlite")
        XCTAssertThrowsError(try SQLiteCorpusStore(url: missing)) { error in
            guard case CorpusStoreError.databaseNotFound = error else {
                return XCTFail("Erreur inattendue : \(error)")
            }
        }
    }

    func testMetadataMatchesTheDatabaseContents() throws {
        let store = try makeStore()
        let metadata = try store.metadata()

        XCTAssertEqual(metadata.sourceProject, "fr.wiktionary.org")
        XCTAssertTrue(
            metadata.licenseName.contains("CC BY-SA"),
            "La licence des contenus repris doit être déclarée : \(metadata.licenseName)"
        )
        XCTAssertEqual(metadata.schemaVersion, SQLiteCorpusStore.supportedSchemaVersion)
        XCTAssertEqual(
            metadata.entryCount,
            try store.entryCount(),
            "Le compte annoncé doit correspondre au contenu réel"
        )
    }

    func testCorpusHoldsAtLeastTheRequiredNumberOfEntries() throws {
        // Le cahier des charges exige au moins 300 fiches réellement vérifiées.
        XCTAssertGreaterThanOrEqual(try makeStore().entryCount(), 300)
    }

    // MARK: - Décodage

    /// Décode **toutes** les fiches : c'est le contrôle d'interopérabilité.
    func testEveryEntryDecodesAndValidates() throws {
        let store = try makeStore()
        var checked = 0
        var problems: [String] = []

        for identifier in try allIdentifiers(store) {
            do {
                guard let entry = try store.entry(withID: identifier) else {
                    problems.append("\(identifier) : candidate mais introuvable")
                    continue
                }
                checked += 1
                let issues = entry.validate()
                if !issues.isEmpty {
                    problems.append("\(identifier) : \(issues.map(\.description).joined(separator: ", "))")
                }
            } catch {
                problems.append("\(identifier) : décodage impossible (\(error))")
            }
        }

        XCTAssertGreaterThan(checked, 0, "Aucune fiche parcourue : le corpus est vide ou illisible")
        XCTAssertTrue(
            problems.isEmpty,
            "\(problems.count) fiche(s) en défaut, dont : \(problems.prefix(5).joined(separator: " | "))"
        )
    }

    func testSummaryCarriesWhatTheWidgetNeeds() throws {
        let store = try makeStore()
        let identifier = try XCTUnwrap(
            try store.candidateIDs(category: .literary, limit: 1).first,
            "Le corpus doit contenir au moins un terme littéraire"
        )
        let summary = try XCTUnwrap(try store.summary(withID: identifier))

        XCTAssertFalse(summary.term.isEmpty)
        XCTAssertFalse(summary.shortDefinition.isEmpty)
        XCTAssertLessThanOrEqual(
            summary.shortDefinition.count,
            LexicalEntry.shortDefinitionMaxLength,
            "Le widget tronque sans prévenir : la production doit contraindre la longueur"
        )
        XCTAssertTrue((1...3).contains(summary.difficulty))
    }

    func testUnknownIdentifierReturnsNothingRatherThanFailing() throws {
        // Une fiche retirée du corpus après une mise à jour doit disparaître de
        // la Collection, pas faire échouer son affichage.
        let store = try makeStore()
        let unknown = EntryID("fiche-qui-n-existe-pas-\(UUID().uuidString)")
        XCTAssertNil(try store.entry(withID: unknown))
        XCTAssertNil(try store.summary(withID: unknown))
        XCTAssertTrue(try store.summaries(withIDs: [unknown]).isEmpty)
    }

    func testSummariesKeepsTheRequestedOrderAndSkipsUnknown() throws {
        let store = try makeStore()
        let identifiers = try store.candidateIDs(category: .expression, limit: 3)
        try XCTSkipIf(identifiers.count < 3, "Corpus trop petit pour ce test")

        let requested = [identifiers[2], EntryID("absent-\(UUID().uuidString)"), identifiers[0]]
        let found = try store.summaries(withIDs: requested)

        XCTAssertEqual(
            found.map(\.id),
            [identifiers[2], identifiers[0]],
            "L'ordre demandé doit être conservé et les inconnus ignorés"
        )
    }

    // MARK: - Ordre des candidats

    /// L'ordre des candidats est le socle du tirage reproductible.
    ///
    /// Le moteur choisit un **rang** dans cette liste. Si l'ordre changeait
    /// entre deux appels ou entre deux processus, le widget et l'application
    /// afficheraient deux termes différents pour le même créneau.
    func testCandidateIdentifiersAreSortedAndStable() throws {
        let store = try makeStore()
        for category in EntryCategory.allCases {
            let identifiers = try store.candidateIDs(category: category, limit: Int.max)
            try XCTSkipIf(identifiers.isEmpty, "Catégorie \(category) vide")
            XCTAssertEqual(
                identifiers,
                identifiers.sorted(),
                "Les candidats de \(category) doivent être triés par identifiant croissant"
            )
            XCTAssertEqual(
                identifiers,
                try store.candidateIDs(category: category, limit: Int.max),
                "Deux appels doivent renvoyer le même ordre"
            )
        }
    }

    func testExclusionsAreAppliedAndCountsAgreeWithThem() throws {
        let store = try makeStore()
        let all = try store.candidateIDs(category: .specialized, limit: Int.max)
        try XCTSkipIf(all.count < 3, "Catégorie trop petite")

        let excluded: Set<EntryID> = [all[0], all[1]]
        let filtered = try store.candidateIDs(category: .specialized, excluding: excluded, limit: Int.max)

        XCTAssertEqual(filtered.count, all.count - 2)
        XCTAssertFalse(filtered.contains(all[0]))
        XCTAssertEqual(
            try store.candidateCount(category: .specialized, excluding: excluded),
            filtered.count,
            "Le compteur et la liste doivent s'accorder, sinon le moteur croira le corpus épuisé"
        )
    }

    func testLimitIsRespected() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.candidateIDs(category: .literary, limit: 5).count, 5)
        XCTAssertTrue(try store.candidateIDs(category: .literary, limit: 0).isEmpty)
    }

    // MARK: - Recherche

    func testSearchIgnoresAccentsAndCase() throws {
        let store = try makeStore()
        // Sans normalisation partagée, « ephemere » ne trouverait pas
        // « éphémère » — le défaut le plus facile à introduire et le plus
        // difficile à remarquer.
        let unaccented = try store.search("ephemere", limit: 20)
        let accented = try store.search("éphémère", limit: 20)
        let shouted = try store.search("ÉPHÉMÈRE", limit: 20)

        XCTAssertFalse(unaccented.isEmpty, "« ephemere » doit trouver « éphémère »")
        XCTAssertEqual(unaccented.map(\.id), accented.map(\.id))
        XCTAssertEqual(accented.map(\.id), shouted.map(\.id))
    }

    func testSearchFindsAMultiWordExpression() throws {
        let store = try makeStore()
        let found = try store.search("victoire pyrrhus", limit: 20)
        XCTAssertTrue(
            found.contains { $0.term.lowercased().contains("pyrrhus") },
            "Une recherche multi-mots doit trouver la locution, dans n'importe quel ordre"
        )
    }

    func testSearchOnNonsenseReturnsNothing() throws {
        let store = try makeStore()
        XCTAssertTrue(try store.search("zzzqqqxxx", limit: 20).isEmpty)
        XCTAssertTrue(try store.search("   ", limit: 20).isEmpty)
        XCTAssertTrue(try store.search("!!!", limit: 20).isEmpty)
    }

    // MARK: - Parcours

    func testBrowsingPaginatesWithoutRepeating() throws {
        let store = try makeStore()
        let first = try store.summaries(category: nil, limit: 20, offset: 0)
        let second = try store.summaries(category: nil, limit: 20, offset: 20)

        XCTAssertEqual(first.count, 20)
        XCTAssertFalse(second.isEmpty)
        XCTAssertTrue(
            Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))),
            "Deux pages ne doivent pas se recouvrir, sinon la Collection afficherait des doublons"
        )
        XCTAssertTrue(try store.summaries(category: nil, limit: 20, offset: -1).isEmpty)
    }

    /// Les termes associés pointent vers des fiches qui existent.
    ///
    /// Un lien mort serait pire qu'une absence de lien : l'utilisateur touche
    /// un mot et tombe sur « terme introuvable ».
    func testEveryRelationPointsToAnExistingEntry() throws {
        let store = try makeStore()
        var checked = 0
        var broken: [String] = []

        for identifier in try allIdentifiers(store) {
            guard let entry = try store.entry(withID: identifier) else { continue }
            for relation in entry.relations {
                checked += 1
                if try store.entry(withID: relation.targetID) == nil {
                    broken.append("\(identifier) → \(relation.targetID)")
                }
                if relation.rationale.trimmingCharacters(in: .whitespaces).isEmpty {
                    broken.append("\(identifier) → \(relation.targetID) : sans justification")
                }
            }
        }

        XCTAssertGreaterThan(checked, 0, "Aucune relation parcourue")
        XCTAssertTrue(
            broken.isEmpty,
            "\(broken.count) lien(s) mort(s) : \(broken.prefix(5).joined(separator: " | "))"
        )
    }
}
