import XCTest
@testable import VocabulleCore

/// Tests du moteur de sélection.
///
/// Les deux exigences structurantes du projet y sont vérifiées noir sur blanc :
/// **un seul moteur pour l'application et le widget**, et **le même créneau
/// donne le même terme partout et à chaque ouverture**.
final class SelectionEngineTests: XCTestCase {

    private static let seed = "graine-de-test"
    private static let referenceNow = UTCTime.instant(2026, 10, 12, 6, 0)

    private func makeEngine(corpus: TestCorpus, seed: String = SelectionEngineTests.seed) -> SelectionEngine {
        SelectionEngine(corpus: corpus, seed: seed)
    }

    private func freshState() -> UserState {
        UserState.initial(seed: Self.seed, now: Self.referenceNow)
    }

    private func slot(_ day: Int, _ period: DayPeriod) -> SlotID {
        SlotID(day: LocalDay(year: 2026, month: 10, day: day), period: period)
    }

    // MARK: - Répartition éditoriale

    func testDistributionCycleMatchesTheRequestedShares() {
        // 40 % littéraire, 25 % expressions, 20 % conversation, 15 % spécialisé,
        // atteints sur chaque cycle de 20 créneaux — pas « en moyenne ».
        let sequence = makeEngine(corpus: TestCorpus.make(perCategory: 5)).categorySequence()
        XCTAssertEqual(sequence.count, SelectionEngine.distributionCycleLength)

        var counts: [EntryCategory: Int] = [:]
        for category in sequence { counts[category, default: 0] += 1 }
        XCTAssertEqual(counts[.literary], 8)
        XCTAssertEqual(counts[.expression], 5)
        XCTAssertEqual(counts[.conversation], 4)
        XCTAssertEqual(counts[.specialized], 3)
    }

    func testDistributionSequenceIsStableForAGivenSeed() {
        let corpus = TestCorpus.make(perCategory: 5)
        XCTAssertEqual(makeEngine(corpus: corpus).categorySequence(), makeEngine(corpus: corpus).categorySequence())
        XCTAssertNotEqual(
            makeEngine(corpus: corpus, seed: "autre-graine").categorySequence(),
            makeEngine(corpus: corpus, seed: Self.seed).categorySequence()
        )
    }

    func testCategoryIsAssignedByCyclePosition() {
        let engine = makeEngine(corpus: TestCorpus.make(perCategory: 5))
        let sequence = engine.categorySequence()

        // Le jour de référence est le premier créneau du premier cycle.
        XCTAssertEqual(engine.cycleIndex(for: SlotID(day: LocalDay(year: 2001, month: 1, day: 1), period: .morning)), 0)
        XCTAssertEqual(engine.cycleIndex(for: SlotID(day: LocalDay(year: 2001, month: 1, day: 1), period: .evening)), 2)
        XCTAssertEqual(engine.cycleIndex(for: SlotID(day: LocalDay(year: 2001, month: 1, day: 2), period: .morning)), 3)

        var cursor = SlotID(day: LocalDay(year: 2001, month: 1, day: 1), period: .morning)
        for index in 0..<25 {
            XCTAssertEqual(engine.category(for: cursor), sequence[index % sequence.count])
            cursor = cursor.next
        }
    }

    // MARK: - Le tirage nominal

    func testNominalDrawIsAPureFunctionOfTheSlot() {
        let engine = makeEngine(corpus: TestCorpus.make(perCategory: 20))
        let target = slot(12, .morning)

        let first = try? engine.nominalEntryID(for: target)
        let second = try? engine.nominalEntryID(for: target)
        XCTAssertNotNil(first ?? nil)
        XCTAssertEqual(first ?? nil, second ?? nil)
    }

    func testNominalDrawIgnoresUserState() {
        // C'est la propriété qui permet au widget de rester exact sans conteneur
        // partagé : le tirage nominal ne consulte aucun état utilisateur.
        let engine = makeEngine(corpus: TestCorpus.make(perCategory: 20))
        let target = slot(12, .morning)
        let nominal = try? engine.nominalEntryID(for: target)

        var hostile = freshState()
        hostile.knownEntryIDs.insert(EntryID("literary-003"))
        hostile.everProposedEntryIDs.insert(EntryID("literary-007"))

        XCTAssertEqual(try? engine.nominalEntryID(for: target), nominal)
    }

    func testResolveOnAFreshStateReturnsTheNominalDraw() {
        // Le terme affiché sur l'écran verrouillé par un widget sans conteneur
        // partagé est exactement celui que l'application calcule sur un état
        // neuf. Toute divergence entre les deux serait un défaut visible.
        let engine = makeEngine(corpus: TestCorpus.make(perCategory: 20))
        let target = slot(12, .morning)

        let nominal = try? engine.nominalEntryID(for: target)
        let result = try? engine.resolve(slot: target, state: freshState(), now: Self.referenceNow)

        XCTAssertEqual(result?.assignment?.entryID, nominal ?? nil)
        XCTAssertEqual(result?.summary?.id, nominal ?? nil)
    }

    func testDifferentSeedsProduceDifferentDraws() {
        let corpus = TestCorpus.make(perCategory: 20)
        let target = slot(12, .morning)
        let a = try? makeEngine(corpus: corpus, seed: "graine-a").nominalEntryID(for: target)
        let b = try? makeEngine(corpus: corpus, seed: "graine-b").nominalEntryID(for: target)
        XCTAssertNotEqual(a ?? nil, b ?? nil)
    }

    // MARK: - Planifié, proposé, consulté

    func testResolvedSlotIsProposedAndRecordedAsAlreadyOffered() {
        let engine = makeEngine(corpus: TestCorpus.make(perCategory: 20))
        let target = slot(12, .morning)
        let result = try? engine.resolve(slot: target, state: freshState(), now: Self.referenceNow)

        XCTAssertEqual(result?.assignment?.status, .proposed)
        XCTAssertEqual(result?.hasEntry, true)
        if let entryID = result?.assignment?.entryID {
            XCTAssertTrue(result?.state.everProposedEntryIDs.contains(entryID) ?? false)
        }
    }

    func testPlanAheadReservesWithoutMarkingAsOffered() {
        // La distinction demandée entre « planifié » et « proposé » : les termes
        // futurs sont mis de côté — donc jamais tirés deux fois — mais
        // n'entrent pas dans la mémoire des termes déjà vus.
        let engine = makeEngine(corpus: TestCorpus.make(perCategory: 20))
        let target = slot(12, .morning)

        let resolved = try? engine.resolve(slot: target, state: freshState(), now: Self.referenceNow)
        var state = resolved?.state ?? freshState()
        state = (try? engine.planAhead(from: target, count: 3, state: state, now: Self.referenceNow)) ?? state

        var cursor = target.next
        for _ in 0..<3 {
            guard let assignment = state[cursor] else {
                return XCTFail("Créneau futur non réservé : \(cursor)")
            }
            XCTAssertEqual(assignment.status, .planned)
            XCTAssertFalse(
                state.everProposedEntryIDs.contains(assignment.entryID),
                "Un créneau seulement planifié ne doit pas compter comme proposé"
            )
            XCTAssertTrue(
                state.liveEntryIDs.contains(assignment.entryID),
                "Un créneau planifié doit tout de même réserver son terme"
            )
            cursor = cursor.next
        }
    }

    func testNoTwoLiveSlotsShareTheSameTerm() {
        let engine = makeEngine(corpus: TestCorpus.make(perCategory: 20))
        let target = slot(12, .morning)

        var state = (try? engine.resolve(slot: target, state: freshState(), now: Self.referenceNow))?.state ?? freshState()
        state = (try? engine.planAhead(from: target, count: 3, state: state, now: Self.referenceNow)) ?? state

        // Un créneau proposé et trois créneaux planifiés : quatre termes
        // distincts, sans quoi deux découvertes seraient identiques.
        XCTAssertEqual(state.liveEntryIDs.count, 4)
    }

    func testMarkConsultedRecordsTheEntryAndTheSlotStatus() {
        let engine = makeEngine(corpus: TestCorpus.make(perCategory: 20))
        let target = slot(12, .morning)
        let resolved = try? engine.resolve(slot: target, state: freshState(), now: Self.referenceNow)
        guard let entryID = resolved?.assignment?.entryID else { return XCTFail("Aucun terme résolu") }

        let consulted = engine.markConsulted(slot: target, state: resolved?.state ?? freshState())
        XCTAssertEqual(consulted[target]?.status, .consulted)
        XCTAssertTrue(consulted.consultedEntryIDs.contains(entryID))
    }

    func testFavouriteTogglesBothWays() {
        let engine = makeEngine(corpus: TestCorpus.make(perCategory: 20))
        let entryID = EntryID("literary-004")

        let added = engine.toggleFavourite(entryID: entryID, state: freshState())
        XCTAssertTrue(added.favouriteEntryIDs.contains(entryID))

        let removed = engine.toggleFavourite(entryID: entryID, state: added)
        XCTAssertFalse(removed.favouriteEntryIDs.contains(entryID))
    }

    // MARK: - Autre mot

    func testReplaceSwapsTheTermWithoutMarkingItKnown() {
        let engine = makeEngine(corpus: TestCorpus.make(perCategory: 20))
        let target = slot(12, .morning)

        let initial = try? engine.resolve(slot: target, state: freshState(), now: Self.referenceNow)
        guard let first = initial?.assignment?.entryID else { return XCTFail("Aucun terme résolu") }

        let replaced = try? engine.replace(slot: target, state: initial?.state ?? freshState(), now: Self.referenceNow)
        guard let second = replaced?.assignment?.entryID else { return XCTFail("Aucun remplacement") }

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(
            replaced?.state.knownEntryIDs.contains(first) ?? true,
            "« Autre mot » ne signifie pas « je connais ce mot »"
        )
        XCTAssertEqual(replaced?.assignment?.previousEntryIDs, [first])
        XCTAssertEqual(replaced?.assignment?.drawSequence, 1)
        XCTAssertEqual(replaced?.assignment?.markedKnown, false)
        XCTAssertTrue(replaced?.state.everProposedEntryIDs.contains(first) ?? false)
    }

    func testReplaceDoesNotImmediatelyRepeatAPreviousTerm() {
        let engine = makeEngine(corpus: TestCorpus.make(perCategory: 20))
        let target = slot(12, .morning)

        var result = try? engine.resolve(slot: target, state: freshState(), now: Self.referenceNow)
        guard let first = result?.assignment?.entryID else { return XCTFail("Aucun terme résolu") }
        result = try? engine.replace(slot: target, state: result?.state ?? freshState(), now: Self.referenceNow)
        guard let second = result?.assignment?.entryID else { return XCTFail("Aucun remplacement") }
        result = try? engine.replace(slot: target, state: result?.state ?? freshState(), now: Self.referenceNow)
        guard let third = result?.assignment?.entryID else { return XCTFail("Aucun second remplacement") }

        XCTAssertNotEqual(third, second)
        XCTAssertNotEqual(third, first)
        XCTAssertEqual(result?.assignment?.previousEntryIDs, [first, second])
        XCTAssertEqual(result?.assignment?.drawSequence, 2)
    }

    func testRepeatedActionReplaysToTheSameTerm() {
        // Une action rejouée — widget rouvert, requête reprise — ne doit pas
        // faire défiler les termes.
        let corpus = TestCorpus.make(perCategory: 20)
        let target = slot(12, .morning)
        let first = makeEngine(corpus: corpus)
        let second = makeEngine(corpus: corpus)

        let a0 = try? first.resolve(slot: target, state: freshState(), now: Self.referenceNow)
        let b0 = try? second.resolve(slot: target, state: freshState(), now: Self.referenceNow)
        XCTAssertEqual(a0?.assignment?.entryID, b0?.assignment?.entryID)

        let a1 = try? first.replace(slot: target, state: a0?.state ?? freshState(), now: Self.referenceNow)
        let b1 = try? second.replace(slot: target, state: b0?.state ?? freshState(), now: Self.referenceNow)
        XCTAssertEqual(a1?.assignment?.entryID, b1?.assignment?.entryID)
    }

    // MARK: - Déjà connu

    func testMarkKnownReplacesTheTermOnTheMatchingSlot() {
        let engine = makeEngine(corpus: TestCorpus.make(perCategory: 20))
        let target = slot(12, .morning)
        let resolved = try? engine.resolve(slot: target, state: freshState(), now: Self.referenceNow)
        guard let entryID = resolved?.assignment?.entryID else { return XCTFail("Aucun terme résolu") }

        let marked = try? engine.markKnown(
            entryID: entryID,
            slot: target,
            state: resolved?.state ?? freshState(),
            now: Self.referenceNow
        )

        XCTAssertTrue(marked?.state.knownEntryIDs.contains(entryID) ?? false)
        XCTAssertNotEqual(marked?.assignment?.entryID, entryID)
        XCTAssertEqual(marked?.assignment?.markedKnown, true)
    }

    func testStaleWidgetActionDoesNotDisturbTheCurrentSlot() {
        // Le cas qui casserait tout : l'utilisateur appuie sur « Déjà connu »
        // pour un terme affiché par un widget périmé, alors que le créneau
        // courant porte déjà un autre terme. Le marquage doit être enregistré,
        // et le créneau courant laissé intact.
        let engine = makeEngine(corpus: TestCorpus.make(perCategory: 20))
        let target = slot(12, .morning)
        let resolved = try? engine.resolve(slot: target, state: freshState(), now: Self.referenceNow)
        guard let current = resolved?.assignment?.entryID else { return XCTFail("Aucun terme résolu") }
        // `effectiveEntryID` renvoie déjà un optionnel : `try?` produit un
        // double optionnel, qu'il faut déplier deux fois.
        guard let stale = (try? engine.effectiveEntryID(
            for: target.next,
            state: resolved?.state ?? freshState()
        )) ?? nil else {
            return XCTFail("Aucun terme pour le créneau suivant")
        }
        XCTAssertNotEqual(stale, current)

        let marked = try? engine.markKnown(
            entryID: stale,
            slot: target,
            state: resolved?.state ?? freshState(),
            now: Self.referenceNow
        )

        XCTAssertTrue(marked?.state.knownEntryIDs.contains(stale) ?? false)
        XCTAssertEqual(marked?.assignment?.entryID, current, "Le créneau courant ne doit pas être remplacé")
    }

    func testUnmarkKnownMakesTheTermAvailableAgain() {
        let engine = makeEngine(corpus: TestCorpus.make(perCategory: 20))
        let entryID = EntryID("literary-002")
        let marked = try? engine.markKnown(
            entryID: entryID,
            slot: slot(12, .morning),
            state: freshState(),
            now: Self.referenceNow
        )
        XCTAssertTrue(marked?.state.knownEntryIDs.contains(entryID) ?? false)

        let cleared = engine.unmarkKnown(entryID: entryID, state: marked?.state ?? freshState())
        XCTAssertFalse(cleared.knownEntryIDs.contains(entryID))
    }

    // MARK: - Épuisement du corpus

    func testACycleCoversEveryCategoryThenReportsExhaustion() {
        // Corpus minuscule : un terme par catégorie. Sur un cycle complet de
        // 20 créneaux, chaque catégorie apparaît au moins une fois, donc
        // exactement quatre tirages aboutissent — un par catégorie.
        let engine = makeEngine(corpus: TestCorpus.make(perCategory: 1))
        var state = freshState()
        var cursor = SlotID(day: LocalDay(year: 2001, month: 1, day: 1), period: .morning)
        var successes = 0

        for _ in 0..<SelectionEngine.distributionCycleLength {
            let result = try? engine.resolve(slot: cursor, state: state, now: Self.referenceNow)
            state = result?.state ?? state
            if result?.hasEntry == true { successes += 1 }
            cursor = cursor.next
        }
        XCTAssertEqual(successes, 4)

        let exhausted = try? engine.resolve(slot: cursor, state: state, now: Self.referenceNow)
        XCTAssertEqual(exhausted?.hasEntry, false)
        XCTAssertNil(exhausted?.assignment ?? nil, "Aucun terme ne doit être inscrit quand le corpus est épuisé")
        XCTAssertEqual(exhausted?.exhaustion?.totalEntries, 4)
        XCTAssertEqual(exhausted?.exhaustion?.knownEntries, 0)
        XCTAssertFalse(exhausted?.exhaustion?.message.isEmpty ?? true)
    }

    func testExhaustionDoesNotHappenWhileTermsRemain() {
        let engine = makeEngine(corpus: TestCorpus.make(perCategory: 20))
        let result = try? engine.resolve(slot: slot(12, .morning), state: freshState(), now: Self.referenceNow)
        XCTAssertNil(result?.exhaustion)
        XCTAssertEqual(result?.hasEntry, true)
    }

    func testNewRoundResetsTheOfferedMemoryButKeepsUserDecisions() {
        // Un tour réellement terminé : tous les termes ont été proposés, et les
        // créneaux anciens ont été élagués — plus aucun n'est « vivant ». C'est
        // la situation que `startNewRoundIfNeeded` doit traiter, et la seule
        // dans laquelle vider la mémoire des termes proposés change quelque
        // chose.
        let engine = makeEngine(corpus: TestCorpus.make(perCategory: 1))
        let target = slot(12, .morning)
        let category = engine.category(for: target)
        let other = EntryCategory.allCases.first { $0 != category } ?? .literary

        var state = freshState()
        state.everProposedEntryIDs = Set(
            EntryCategory.allCases.map { EntryID("\($0.rawValue)-000") }
        )
        // Le favori est précisément le terme que le tour suivant doit pouvoir
        // reproposer : un favori ne se transforme pas en exclusion.
        let favourite = EntryID("\(category.rawValue)-000")
        state.favouriteEntryIDs.insert(favourite)
        state.knownEntryIDs.insert(EntryID("\(other.rawValue)-000"))

        // Sans nouveau tour, plus rien n'est disponible.
        let blocked = try? engine.resolve(slot: target, state: state, now: Self.referenceNow)
        XCTAssertEqual(blocked?.hasEntry, false)
        XCTAssertEqual(blocked?.exhaustion?.totalEntries, 4)

        guard let next = try? engine.startNewRoundIfNeeded(state: state, now: Self.referenceNow) else {
            return XCTFail("Aucun nouveau tour ouvert")
        }
        XCTAssertEqual(next.roundCount, 1)
        XCTAssertTrue(next.everProposedEntryIDs.isEmpty, "La mémoire des termes proposés est vidée")
        XCTAssertTrue(next.favouriteEntryIDs.contains(favourite), "Les favoris survivent au changement de tour")
        XCTAssertTrue(
            next.knownEntryIDs.contains(EntryID("\(other.rawValue)-000")),
            "« Déjà connu » survit au changement de tour"
        )

        let afterReset = try? engine.resolve(slot: target, state: next, now: Self.referenceNow)
        XCTAssertEqual(afterReset?.assignment?.entryID, favourite, "Le tour suivant peut reproposer un terme déjà vu")
    }

    func testNewRoundIsNotOpenedWhileTermsRemain() {
        let engine = makeEngine(corpus: TestCorpus.make(perCategory: 20))
        let state = try? engine.startNewRoundIfNeeded(state: freshState(), now: Self.referenceNow)
        XCTAssertEqual(state?.roundCount, 0)
    }
}
