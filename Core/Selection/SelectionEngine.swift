import Foundation

/// Résultat de la résolution d'un créneau.
public struct SelectionResult: Sendable {
    public let slot: SlotID
    public let assignment: SlotAssignment?
    public let summary: EntrySummary?
    public let state: UserState
    /// Renseigné lorsque le corpus est épuisé.
    public let exhaustion: CorpusExhaustion?

    public var hasEntry: Bool { assignment != nil }
}

/// État d'épuisement du corpus.
///
/// Le projet demande de gérer explicitement ce cas plutôt que de boucler
/// indéfiniment ou de reproposer les mêmes termes en silence.
public struct CorpusExhaustion: Sendable, Equatable {
    public let totalEntries: Int
    public let knownEntries: Int

    public var message: String {
        "Vous avez parcouru les \(totalEntries) termes du corpus. Les découvertes reprennent au début ; décochez « déjà connu » pour revoir un terme."
    }
}

/// Moteur de sélection, partagé par l'application et l'extension widget.
///
/// # Le tirage nominal
///
/// `nominalEntryID(for:)` est une **fonction pure** de la graine et de
/// l'identifiant du créneau. Elle ne dépend d'aucun état utilisateur, et c'est
/// délibéré.
///
/// La raison est concrète : un profil de provisionnement délivré à un compte
/// Apple gratuit ne contient pas l'entitlement `com.apple.security.application-groups`,
/// et un build non signé ne porte aucun entitlement — AltStore re-signe donc
/// l'application sans le groupe partagé. L'extension widget n'a alors aucun
/// accès à l'état de l'application.
///
/// Grâce au tirage nominal, le widget reste exact dans le cas courant : le
/// terme affiché sur l'écran verrouillé est celui que l'application afficherait
/// si l'utilisateur n'était pas intervenu. Les interventions — « Autre mot »,
/// « Déjà connu » — sont des **écarts** enregistrés côté application, que le
/// widget ne voit pas. Les réglages le disent explicitement plutôt que de
/// laisser croire à un partage qui n'existe pas.
///
/// # La sonde
///
/// Lorsqu'un terme tiré est exclu — déjà connu, déjà proposé, réservé par un
/// autre créneau — le moteur avance dans la liste ordonnée jusqu'au premier
/// candidat libre. La progression est déterministe : la même exclusion produit
/// toujours le même remplacement.
public struct SelectionEngine: Sendable {
    public var corpus: CorpusStore
    public var seed: String

    public init(corpus: CorpusStore, seed: String) {
        self.corpus = corpus
        self.seed = seed
    }

    /// Longueur du cycle de répartition éditoriale.
    ///
    /// Vingt créneaux, soit 8 littéraires, 5 expressions, 4 conversations et
    /// 3 termes spécialisés : exactement les proportions 40/25/20/15 demandées,
    /// atteintes sur chaque cycle plutôt qu'« en moyenne ».
    public static let distributionCycleLength = 20

    /// Jour de référence du calcul de rang. Fixe pour toujours.
    static let referenceDay = LocalDay(year: 2001, month: 1, day: 1)

    /// Suite des catégories sur un cycle, mélangée une fois pour la graine.
    ///
    /// Le mélange évite qu'un utilisateur voie huit mots littéraires d'affilée
    /// en début de cycle, tout en garantissant les proportions exactes.
    public func categorySequence() -> [EntryCategory] {
        var pool: [EntryCategory] = []
        for category in EntryCategory.allCases {
            let count = category.targetShare * Self.distributionCycleLength / 100
            pool.append(contentsOf: Array(repeating: category, count: count))
        }
        var random = StableRandom(seedParts: [seed, "distribution"])
        var result = pool
        for index in stride(from: result.count - 1, to: 0, by: -1) {
            result.swapAt(index, random.nextInt(upperBound: index + 1))
        }
        return result
    }

    /// Rang du créneau dans la succession des créneaux depuis le jour de
    /// référence. Stable pour toujours, indépendamment de la date
    /// d'installation.
    public func cycleIndex(for slot: SlotID) -> Int {
        let calendar = Calendar.vocabulle
        let reference = calendar.date(from: DateComponents(
            year: Self.referenceDay.year,
            month: Self.referenceDay.month,
            day: Self.referenceDay.day
        ))
        let target = calendar.date(from: DateComponents(
            year: slot.day.year,
            month: slot.day.month,
            day: slot.day.day
        ))
        let days: Int
        if let reference, let target {
            days = calendar.dateComponents([.day], from: reference, to: target).day ?? 0
        } else {
            days = 0
        }
        return days * DayPeriod.allCases.count + slot.period.order
    }

    /// Catégorie attribuée à un créneau par le cycle éditorial.
    public func category(for slot: SlotID) -> EntryCategory {
        let sequence = categorySequence()
        guard !sequence.isEmpty else { return .literary }
        let index = cycleIndex(for: slot)
        let position = ((index % sequence.count) + sequence.count) % sequence.count
        return sequence[position]
    }

    /// Tirage nominal : terme de référence d'un créneau, sans aucun état.
    ///
    /// C'est la fonction que l'extension widget appelle lorsqu'aucun conteneur
    /// partagé n'est disponible.
    public func nominalEntryID(for slot: SlotID, round: Int = 0) throws -> EntryID? {
        let category = self.category(for: slot)
        let candidates = try corpus.candidateIDs(category: category, excluding: [], limit: Int.max)
        guard !candidates.isEmpty else { return nil }
        var random = StableRandom(seedParts: [
            seed,
            slot.description,
            category.rawValue,
            String(round)
        ])
        return candidates[random.nextInt(upperBound: candidates.count)]
    }

    /// Terme effectif d'un créneau, en tenant compte des exclusions.
    ///
    /// Part du tirage nominal puis avance dans la liste ordonnée jusqu'au
    /// premier candidat disponible. Renvoie `nil` si la catégorie est
    /// entièrement consommée.
    public func effectiveEntryID(for slot: SlotID, state: UserState) throws -> EntryID? {
        let category = self.category(for: slot)
        let candidates = try corpus.candidateIDs(category: category, excluding: [], limit: Int.max)
        guard !candidates.isEmpty else { return nil }

        let excluded = state.excludedEntryIDs()
        if let nominal = try nominalEntryID(for: slot, round: state.roundCount),
           let start = candidates.firstIndex(of: nominal) {
            // Sonde circulaire : on repart au début si la fin de liste est
            // atteinte, pour ne pas privilégier systématiquement les termes
            // dont l'identifiant est proche de « a ».
            for offset in 0..<candidates.count {
                let candidate = candidates[(start + offset) % candidates.count]
                if !excluded.contains(candidate) { return candidate }
            }
        }
        return candidates.first { !excluded.contains($0) }
    }

    /// Résout un créneau : lit le registre, complète ce qui manque.
    ///
    /// N'écrit rien : l'appelant décide de persister. Cette séparation permet
    /// au widget de résoudre un créneau en lecture seule.
    public func resolve(slot: SlotID, state: UserState, now: Date) throws -> SelectionResult {
        var working = state

        if var existing = working[slot] {
            // Un créneau réservé qui commence devient « proposé ».
            if existing.status == .planned {
                existing.status = .proposed
                working[slot] = existing
            }
            return SelectionResult(
                slot: slot,
                assignment: existing,
                summary: try corpus.summary(withID: existing.entryID),
                state: working,
                exhaustion: nil
            )
        }

        guard let entryID = try effectiveEntryID(for: slot, state: working) else {
            return SelectionResult(
                slot: slot,
                assignment: nil,
                summary: nil,
                state: working,
                exhaustion: exhaustion(for: working)
            )
        }

        let assignment = SlotAssignment(entryID: entryID, status: .proposed, assignedAt: now)
        working[slot] = assignment
        working.everProposedEntryIDs.insert(entryID)
        return SelectionResult(
            slot: slot,
            assignment: assignment,
            summary: try corpus.summary(withID: entryID),
            state: working,
            exhaustion: nil
        )
    }

    /// Réserve les prochains créneaux sans les marquer comme proposés.
    ///
    /// C'est la distinction demandée entre « planifié » et « proposé » : les
    /// termes futurs sont mis de côté — donc jamais tirés deux fois — mais
    /// n'entrent pas dans la mémoire des termes déjà vus, qui doit refléter ce
    /// que l'utilisateur a réellement pu voir.
    public func planAhead(
        from slot: SlotID,
        count: Int,
        state: UserState,
        now: Date
    ) throws -> UserState {
        guard count > 0 else { return state }
        var working = state
        var cursor = slot.next
        for _ in 0..<count {
            if working[cursor] == nil,
               let entryID = try effectiveEntryID(for: cursor, state: working) {
                working[cursor] = SlotAssignment(entryID: entryID, status: .planned, assignedAt: now)
            }
            cursor = cursor.next
        }
        return working
    }

    /// Remplace le terme d'un créneau (« Autre mot »).
    ///
    /// Le terme écarté n'est **pas** marqué comme connu : l'utilisateur n'a pas
    /// dit le connaître, seulement qu'il veut voir autre chose. Il est conservé
    /// dans l'historique du créneau pour ne pas réapparaître aussitôt.
    public func replace(slot: SlotID, state: UserState, now: Date) throws -> SelectionResult {
        var working = state
        let previous = working[slot]
        if let previous { working.everProposedEntryIDs.insert(previous.entryID) }

        guard let entryID = try effectiveEntryID(for: slot, state: working) else {
            return SelectionResult(
                slot: slot,
                assignment: previous,
                summary: nil,
                state: working,
                exhaustion: exhaustion(for: working)
            )
        }

        var history = previous?.previousEntryIDs ?? []
        if let previous { history.append(previous.entryID) }
        let assignment = SlotAssignment(
            entryID: entryID,
            status: .proposed,
            assignedAt: now,
            drawSequence: (previous?.drawSequence ?? 0) + 1,
            previousEntryIDs: history,
            markedKnown: false
        )
        working[slot] = assignment
        working.everProposedEntryIDs.insert(entryID)
        return SelectionResult(
            slot: slot,
            assignment: assignment,
            summary: try corpus.summary(withID: entryID),
            state: working,
            exhaustion: nil
        )
    }

    /// Marque un terme comme déjà connu.
    ///
    /// S'il occupe le créneau indiqué, il y est immédiatement remplacé :
    /// laisser affiché un terme qu'on vient de déclarer connu serait
    /// incohérent. S'il ne l'occupe pas — cas d'une action provenant d'un
    /// widget périmé — seul le marquage est enregistré, et le créneau courant
    /// n'est pas touché.
    public func markKnown(
        entryID: EntryID,
        slot: SlotID,
        state: UserState,
        now: Date
    ) throws -> SelectionResult {
        var marked = state
        marked.knownEntryIDs.insert(entryID)
        marked.everProposedEntryIDs.insert(entryID)

        guard marked[slot]?.entryID == entryID else {
            return SelectionResult(
                slot: slot,
                assignment: marked[slot],
                summary: try marked[slot].flatMap { try corpus.summary(withID: $0.entryID) },
                state: marked,
                exhaustion: nil
            )
        }

        var replaced = try replace(slot: slot, state: marked, now: now)
        if var assignment = replaced.assignment {
            assignment.markedKnown = true
            var finalState = replaced.state
            finalState[slot] = assignment
            replaced = SelectionResult(
                slot: replaced.slot,
                assignment: assignment,
                summary: replaced.summary,
                state: finalState,
                exhaustion: replaced.exhaustion
            )
        }
        return replaced
    }

    /// Annule un marquage « déjà connu ».
    public func unmarkKnown(entryID: EntryID, state: UserState) -> UserState {
        var working = state
        working.knownEntryIDs.remove(entryID)
        return working
    }

    /// Enregistre l'ouverture d'une fiche.
    public func markConsulted(slot: SlotID, state: UserState) -> UserState {
        var working = state
        guard var assignment = working[slot] else { return working }
        working.consultedEntryIDs.insert(assignment.entryID)
        assignment.status = .consulted
        working[slot] = assignment
        return working
    }

    /// Bascule un favori.
    public func toggleFavourite(entryID: EntryID, state: UserState) -> UserState {
        var working = state
        if working.favouriteEntryIDs.contains(entryID) {
            working.favouriteEntryIDs.remove(entryID)
        } else {
            working.favouriteEntryIDs.insert(entryID)
        }
        return working
    }

    /// Prépare le tour suivant lorsque plus aucun terme n'est disponible.
    ///
    /// On incrémente `roundCount` et on vide la mémoire des termes proposés :
    /// le second tour ne reprend donc pas les termes dans le même ordre. Les
    /// favoris et les termes marqués connus sont conservés — ce sont des
    /// décisions de l'utilisateur, pas un état de progression.
    public func startNewRoundIfNeeded(state: UserState, now: Date) throws -> UserState {
        for category in EntryCategory.allCases {
            let available = try corpus.candidateCount(
                category: category,
                excluding: state.excludedEntryIDs()
            )
            if available > 0 { return state }
        }
        var working = state
        working.roundCount += 1
        working.everProposedEntryIDs.removeAll()
        working.updatedAt = now
        return working
    }

    private func exhaustion(for state: UserState) -> CorpusExhaustion {
        CorpusExhaustion(
            totalEntries: (try? corpus.entryCount()) ?? 0,
            knownEntries: state.knownEntryIDs.count
        )
    }
}
