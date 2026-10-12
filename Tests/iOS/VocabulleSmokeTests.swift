import XCTest
@testable import Vocabulle

/// Tests d'intégration de l'application, exécutés dans le simulateur.
///
/// # Ce que ces tests couvrent, et ce qu'ils ne couvrent pas
///
/// Ils vérifient ce qui ne peut l'être que dans le bundle réel de
/// l'application : le corpus embarqué s'ouvre, les liens profonds se décodent,
/// et deux lectures indépendantes du même créneau donnent le même terme.
///
/// Ils ne vérifient **pas** le partage avec le widget : un simulateur n'accorde
/// pas de conteneur partagé, et un build de CI n'est pas signé avec
/// l'entitlement de groupe. Cette validation-là n'a lieu que sur un appareil
/// réel, et elle est décrite dans `docs/VALIDATION_MANUELLE.md`. Prétendre le
/// contraire ici serait exactement l'annonce que le cahier des charges
/// interdit.
@MainActor
final class VocabulleSmokeTests: XCTestCase {

    // MARK: - Corpus embarqué

    func testCorpusIsEmbeddedAndOpens() throws {
        let url = try EmbeddedCorpus.url(in: .main)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Le corpus doit être présent dans le bundle : \(url.lastPathComponent)"
        )

        let corpus = try EmbeddedCorpus.open(in: .main)
        XCTAssertGreaterThanOrEqual(
            try corpus.entryCount(),
            300,
            "Le corpus livré doit contenir au moins 300 fiches vérifiées"
        )
    }

    func testEmbeddedCorpusMetadataIsReadable() throws {
        let metadata = try EmbeddedCorpus.open(in: .main).metadata()
        XCTAssertEqual(metadata.sourceProject, "fr.wiktionary.org")
        XCTAssertTrue(metadata.licenseName.contains("CC BY-SA"))
        XCTAssertFalse(metadata.pipelineVersion.isEmpty)
    }

    // MARK: - Liens profonds

    func testDeepLinkRoundTrips() {
        let identifier = EntryID("monomaniaque")
        let url = DeepLink.url(for: identifier)
        XCTAssertEqual(url.scheme, "vocabulle")

        guard case .entry(let parsed) = DeepLink(url: url) else {
            return XCTFail("Le lien \(url) doit désigner une fiche")
        }
        XCTAssertEqual(parsed, identifier)
    }

    func testDeepLinkRejectsForeignURLs() {
        XCTAssertNil(DeepLink(url: URL(string: "https://example.com/terme/chat")!))
        XCTAssertNil(DeepLink(url: URL(string: "vocabulle://autrechose")!))
        XCTAssertNil(DeepLink(url: URL(string: "vocabulle://terme/")!))
    }

    /// Le lien doit survivre à un identifiant accentué.
    ///
    /// C'est ce qui garantit qu'un widget posé sur « éphémère » ouvre
    /// « éphémère » et pas autre chose.
    func testDeepLinkSurvivesAnAccentedIdentifier() {
        let identifier = EntryID(EntryID.slug(from: "éphémère"))
        XCTAssertEqual(identifier.rawValue, "ephemere")
        guard case .entry(let parsed) = DeepLink(url: DeepLink.url(for: identifier)) else {
            return XCTFail("Lien non reconnu")
        }
        XCTAssertEqual(parsed, identifier)
    }

    // MARK: - Même terme partout

    /// Deux lectures indépendantes du même créneau donnent le même terme.
    ///
    /// C'est la garantie centrale du projet : l'écran verrouillé et l'écran
    /// Aujourd'hui ne peuvent pas diverger. On la vérifie en construisant deux
    /// sessions distinctes, comme le font l'application et l'extension — deux
    /// objets, deux connexions au corpus, un seul résultat attendu.
    func testTwoIndependentSessionsAgreeOnTheSameSlot() throws {
        let corpus = try EmbeddedCorpus.open(in: .main)
        let container = SharedContainer.resolve()
        let instant = Date()

        let first = VocabulleSession(container: container, corpus: corpus, clock: FixedClock(instant))
        let second = VocabulleSession(container: container, corpus: corpus, clock: FixedClock(instant))

        let a = try first.snapshot()
        let b = try second.snapshot()

        XCTAssertEqual(a.slot, b.slot)
        XCTAssertEqual(a.entryID, b.entryID)
    }

    func testSnapshotAlwaysDesignatesAnExistingEntry() throws {
        let corpus = try EmbeddedCorpus.open(in: .main)
        let session = VocabulleSession(container: SharedContainer.resolve(), corpus: corpus)
        let snapshot = try session.snapshot()

        guard let entryID = snapshot.entryID else {
            // Un corpus épuisé est un cas légitime, mais il doit alors le dire.
            XCTAssertNotNil(snapshot.exhaustion, "Sans terme, l'épuisement doit être expliqué")
            return
        }
        XCTAssertNotNil(
            try session.entry(withID: entryID),
            "Le terme annoncé doit exister dans le corpus"
        )
        XCTAssertNotNil(
            snapshot.summary,
            "Le widget a besoin du résumé, pas seulement de l'identifiant"
        )
    }

    // MARK: - Conteneur partagé

    /// La résolution ne doit jamais échouer, même sans conteneur partagé.
    ///
    /// Sur un simulateur — et sur un appareil installé par AltStore avec un
    /// compte Apple gratuit — `containerURL` renvoie `nil` sans erreur. Le
    /// projet interdit de compenser par un second magasin privé : le widget
    /// afficherait alors un terme différent de celui de l'application.
    func testSharedContainerResolvesToSomethingUsable() {
        let container = SharedContainer.resolve()
        XCTAssertFalse(container.directory.path.isEmpty)
        XCTAssertEqual(container.stateURL.lastPathComponent, SharedContainer.stateFileName)
        XCTAssertEqual(
            container.cacheDirectory.lastPathComponent,
            SharedContainer.cacheDirectoryName
        )
    }

    // MARK: - Réglages

    func testDefaultScheduleMatchesTheDocumentedTimes() {
        let schedule = VocabulleSettings.default.schedule
        XCTAssertEqual(schedule.morning, TimeOfDay(hour: 8))
        XCTAssertEqual(schedule.afternoon, TimeOfDay(hour: 14))
        XCTAssertEqual(schedule.evening, TimeOfDay(hour: 20))
        XCTAssertFalse(
            VocabulleSettings.default.notificationsEnabled,
            "Les notifications sont désactivées par défaut"
        )
    }
}
