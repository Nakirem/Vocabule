import XCTest
@testable import VocabulleCore

/// Tests de l'état partagé entre l'application et l'extension widget.
///
/// C'est la couche la plus risquée du projet : deux processus écrivent le même
/// fichier, et une perte de données ici efface les favoris et l'historique de
/// l'utilisateur — les seules choses qu'il a construites lui-même.
final class UserStateStoreTests: XCTestCase {

    private static let now = UTCTime.instant(2026, 10, 12, 6, 0)

    /// Magasin isolé dans un dossier temporaire jetable.
    ///
    /// Aucun test ne touche au conteneur partagé réel : sur un runner
    /// d'intégration continue il n'existe pas, et sur une machine de
    /// développement il ne faut pas y écrire.
    private func makeStore() -> UserStateStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulle-etat-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return UserStateStore(container: SharedContainer(tier: .isolated, directory: directory))
    }

    private func initialState(seed: String = "graine-de-test") -> UserState {
        UserState.initial(seed: seed, now: Self.now)
    }

    private func directoryContents(of store: UserStateStore) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: store.container.directory.path)) ?? []
    }

    // MARK: - Aller-retour

    func testStateSurvivesARoundTrip() throws {
        let store = makeStore()
        var state = initialState()
        let slot = SlotID(day: LocalDay(year: 2026, month: 10, day: 12), period: .morning)
        state[slot] = SlotAssignment(entryID: EntryID("literary-000"), status: .proposed, assignedAt: Self.now)
        state.favouriteEntryIDs.insert(EntryID("expression-002"))
        state.knownEntryIDs.insert(EntryID("conversation-001"))

        let saved = try store.save(state, now: Self.now)
        let loaded = try store.load()

        XCTAssertEqual(loaded, saved)
        XCTAssertEqual(loaded[slot]?.entryID, EntryID("literary-000"))
        XCTAssertTrue(loaded.favouriteEntryIDs.contains(EntryID("expression-002")))
        XCTAssertTrue(loaded.knownEntryIDs.contains(EntryID("conversation-001")))
    }

    func testRevisionIncreasesOnEveryWrite() throws {
        let store = makeStore()
        // L'état initial porte déjà la révision 1 : c'est la première écriture
        // logique, pas zéro.
        let first = try store.save(initialState(), now: Self.now)
        XCTAssertEqual(first.revision, 2)

        let second = try store.save(first, now: Self.now)
        XCTAssertEqual(second.revision, 3)
        XCTAssertEqual(try store.load().revision, 3)
    }

    // MARK: - Première installation

    func testLoadOrCreateReturnsAFreshStateWithoutWriting() throws {
        let store = makeStore()
        let state = try store.loadOrCreate(seed: "graine-initiale", now: Self.now)

        XCTAssertEqual(state.revision, 1)
        XCTAssertEqual(state.selectionSeed, "graine-initiale")
        XCTAssertTrue(state.assignments.isEmpty)
        XCTAssertFalse(state.hasCompletedOnboarding)
        // La graine ne doit pas être régénérée à chaque lecture : si le fichier
        // n'existe pas encore, c'est à l'appelant d'écrire une fois pour toutes.
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.container.stateURL.path))
    }

    func testLoadOrCreateReadsAnExistingState() throws {
        let store = makeStore()
        var state = initialState()
        state.hasCompletedOnboarding = true
        try store.save(state, now: Self.now)

        let loaded = try store.loadOrCreate(seed: "graine-qui-ne-doit-pas-servir", now: Self.now)
        XCTAssertTrue(loaded.hasCompletedOnboarding)
        XCTAssertEqual(loaded.selectionSeed, "graine-de-test")
    }

    // MARK: - Rejeu des transformations

    func testUpdateReplaysTheTransformOnFreshState() throws {
        let store = makeStore()
        try store.save(initialState(), now: Self.now)

        let updated = try store.update(now: Self.now) { state in
            var copy = state
            copy.knownEntryIDs.insert(EntryID("literary-000"))
            return copy
        }

        XCTAssertTrue(updated.knownEntryIDs.contains(EntryID("literary-000")))
        XCTAssertEqual(updated.revision, 3, "1 à la création, 2 après save, 3 après update")
        XCTAssertEqual(try store.load().knownEntryIDs, updated.knownEntryIDs)
    }

    func testUpdateCreatesStateWhenNoneExistsYet() throws {
        // `update` commence par `load()`, donc sur une installation neuve le
        // fichier n'existe pas encore : on écrit un état initial avant de
        // rejouer la transformation.
        let store = makeStore()
        try store.save(initialState(), now: Self.now)
        let updated = try store.update(now: Self.now) { $0 }
        XCTAssertEqual(updated.revision, 3)
    }

    // MARK: - Fichier illisible

    func testCorruptedFileIsQuarantinedNotDeleted() throws {
        let store = makeStore()
        let url = store.container.stateURL
        try Data("ceci n'est pas du JSON".utf8).write(to: url)

        XCTAssertThrowsError(try store.load()) { error in
            guard case UserStateStoreError.corruptedFile = error else {
                return XCTFail("Erreur inattendue : \(error)")
            }
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "Le fichier illisible est déplacé, sans quoi chaque lecture échouerait de nouveau"
        )
        let quarantined = directoryContents(of: store).filter { $0.hasPrefix("state.json.corrompu-") }
        XCTAssertEqual(quarantined.count, 1, "Le contenu d'origine doit rester diagnosticable")
    }

    func testStateCanBeRebuiltAfterAQuarantine() throws {
        let store = makeStore()
        try Data("illisible".utf8).write(to: store.container.stateURL)
        XCTAssertThrowsError(try store.load())

        // L'application doit rester utilisable : une nouvelle écriture repart
        // d'un état sain.
        let rebuilt = try store.save(initialState(seed: "graine-reprise"), now: Self.now)
        XCTAssertEqual(rebuilt.selectionSeed, "graine-reprise")
        XCTAssertEqual(try store.load().selectionSeed, "graine-reprise")
    }

    func testStateFromANewerVersionIsRefusedButPreserved() throws {
        let store = makeStore()
        try store.save(initialState(), now: Self.now)

        let url = store.container.stateURL
        let data = try Data(contentsOf: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = UserState.currentSchemaVersion + 1
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)

        XCTAssertThrowsError(try store.load()) { error in
            guard case UserStateStoreError.unsupportedSchema(let found, let supported) = error else {
                return XCTFail("Erreur inattendue : \(error)")
            }
            XCTAssertEqual(found, UserState.currentSchemaVersion + 1)
            XCTAssertEqual(supported, UserState.currentSchemaVersion)
        }

        // Une version plus récente n'est pas un fichier corrompu : la mettre de
        // côté détruirait des données qu'une version à jour saurait encore lire.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(directoryContents(of: store).contains { $0.contains(".corrompu-") })
    }

    // MARK: - Format du fichier

    func testStateFileIsSortedIso8601Json() throws {
        let store = makeStore()
        try store.save(initialState(), now: Self.now)

        let data = try Data(contentsOf: store.container.stateURL)
        let raw = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(raw.hasPrefix("{\"assignments\":"), "Clés triées : \(raw.prefix(60))")
        XCTAssertTrue(raw.contains("\"2026-10-12T06:00:00Z\""), "Dates ISO 8601 attendues : \(raw)")
    }

    func testWritingTheSameStateTwiceProducesTheSameBytes() throws {
        // Sans tri des clés, chaque écriture ferait « changer » le fichier aux
        // yeux de tout outil qui le compare, et l'horodatage seul suffirait à
        // invalider un cache côté widget.
        let store = makeStore()
        let state = initialState()
        try store.save(state, now: Self.now)
        let first = try Data(contentsOf: store.container.stateURL)

        try store.save(state, now: Self.now)
        let second = try Data(contentsOf: store.container.stateURL)

        XCTAssertEqual(first, second)
    }

    // MARK: - Migration

    func testMigrationFillsAMissingSeedStably() throws {
        let store = makeStore()
        var bare = initialState(seed: "")
        bare.knownEntryIDs.insert(EntryID("literary-000"))
        try store.save(bare, now: Self.now)

        let first = try store.load()
        XCTAssertFalse(first.selectionSeed.isEmpty, "Une graine absente doit être reconstruite")

        let second = try store.load()
        XCTAssertEqual(first.selectionSeed, second.selectionSeed, "La graine de secours est stable pour un état donné")
    }

    func testMigrationKeepsAnExistingSeed() {
        let state = initialState(seed: "graine-utilisateur")
        XCTAssertEqual(UserStateStore.migrate(state).selectionSeed, "graine-utilisateur")
    }

    // MARK: - Élagage et exclusions

    func testPruningKeepsRecentSlotsAndNeverDropsAPlannedOne() {
        var state = initialState()
        for day in 1...5 {
            let slot = SlotID(day: LocalDay(year: 2026, month: 10, day: day), period: .morning)
            state[slot] = SlotAssignment(entryID: EntryID("terme-\(day)"), status: .proposed, assignedAt: Self.now)
        }
        let planned = SlotID(day: LocalDay(year: 2026, month: 10, day: 7), period: .morning)
        state[planned] = SlotAssignment(entryID: EntryID("reserve"), status: .planned, assignedAt: Self.now)

        let cutoff = SlotID(day: LocalDay(year: 2026, month: 10, day: 6), period: .morning)
        let prunedState = state.pruned(keepingPastSlots: 2, before: cutoff)

        XCTAssertEqual(prunedState.assignments.count, 3)
        XCTAssertNotNil(prunedState[SlotID(day: LocalDay(year: 2026, month: 10, day: 4), period: .morning)])
        XCTAssertNotNil(prunedState[SlotID(day: LocalDay(year: 2026, month: 10, day: 5), period: .morning)])
        XCTAssertNotNil(prunedState[planned], "Élaguer un créneau planifié ferait reproposer un terme déjà réservé")
        XCTAssertNil(prunedState[SlotID(day: LocalDay(year: 2026, month: 10, day: 1), period: .morning)])
    }

    func testPruningLeavesStateUntouchedWhenThereIsNothingToRemove() {
        var state = initialState()
        for day in 1...3 {
            let slot = SlotID(day: LocalDay(year: 2026, month: 10, day: day), period: .morning)
            state[slot] = SlotAssignment(entryID: EntryID("terme-\(day)"), status: .proposed, assignedAt: Self.now)
        }
        let cutoff = SlotID(day: LocalDay(year: 2026, month: 10, day: 6), period: .morning)
        XCTAssertEqual(state.pruned(keepingPastSlots: 10, before: cutoff).assignments.count, 3)
    }

    func testExcludedEntriesCombineKnownLiveAndAlreadyOffered() {
        var state = initialState()
        state.knownEntryIDs.insert(EntryID("connu"))
        state.everProposedEntryIDs.insert(EntryID("deja-propose"))
        let slot = SlotID(day: LocalDay(year: 2026, month: 10, day: 12), period: .morning)
        state[slot] = SlotAssignment(
            entryID: EntryID("affiche"),
            status: .proposed,
            assignedAt: Self.now,
            previousEntryIDs: [EntryID("ecarte")]
        )

        let excluded = state.excludedEntryIDs()
        XCTAssertTrue(excluded.contains(EntryID("connu")))
        XCTAssertTrue(excluded.contains(EntryID("deja-propose")))
        XCTAssertTrue(excluded.contains(EntryID("affiche")))
        XCTAssertTrue(
            excluded.contains(EntryID("ecarte")),
            "Un terme écarté par « Autre mot » ne doit pas revenir au créneau suivant"
        )
        XCTAssertFalse(excluded.contains(EntryID("libre")))
        XCTAssertEqual(state.liveEntryIDs, [EntryID("affiche"), EntryID("ecarte")])
    }

    // MARK: - Conteneur partagé

    func testResolveFallsBackToIsolatedWhenNoGroupIsAvailable() {
        // C'est le cas réel d'une installation AltStore avec un compte Apple
        // gratuit : le profil ne porte pas l'entitlement de groupe, et
        // `containerURL` renvoie nil sans erreur.
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulle-repli-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: fallback) }

        let container = SharedContainer.resolve(
            bundle: .main,
            fallbackDirectory: fallback,
            containerURLProvider: { _ in nil }
        )

        XCTAssertEqual(container.tier, .isolated)
        XCTAssertNil(container.groupIdentifier)
        XCTAssertEqual(container.directory, fallback)
        XCTAssertEqual(
            container.attemptedGroupIdentifiers,
            SharedContainer.candidateGroupIdentifiers(bundle: .main),
            "Les réglages affichent ce qui a été tenté : la liste doit être complète"
        )
    }

    func testResolveUsesTheGroupWhenItIsAvailable() {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulle-groupe-\(UUID().uuidString)", isDirectory: true)
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulle-repli-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: groupURL) }

        let container = SharedContainer.resolve(
            bundle: .main,
            fallbackDirectory: fallback,
            containerURLProvider: { _ in groupURL }
        )

        XCTAssertEqual(container.tier, .appGroup)
        XCTAssertEqual(container.directory, groupURL)
        XCTAssertEqual(container.groupIdentifier, SharedContainer.candidateGroupIdentifiers(bundle: .main).first)
    }

    func testCandidateGroupIdentifiersAlwaysIncludeTheDeclaredGroup() {
        let candidates = SharedContainer.candidateGroupIdentifiers(bundle: .main)
        XCTAssertTrue(candidates.contains(SharedContainer.declaredGroupIdentifier))
        XCTAssertEqual(Set(candidates).count, candidates.count, "Aucun identifiant tenté deux fois")
        XCTAssertFalse(candidates.contains(""), "Un identifiant vide ne doit pas être tenté")
    }

    func testStateAndCacheLiveInTheSameContainer() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulle-chemins-\(UUID().uuidString)", isDirectory: true)
        let container = SharedContainer(tier: .isolated, directory: directory)

        XCTAssertEqual(container.stateURL.lastPathComponent, "state.json")
        XCTAssertEqual(container.cacheDirectory.lastPathComponent, "CorpusCache")
        XCTAssertEqual(container.stateURL.deletingLastPathComponent(), container.directory)
        XCTAssertEqual(container.cacheDirectory.deletingLastPathComponent(), container.directory)
    }
}
