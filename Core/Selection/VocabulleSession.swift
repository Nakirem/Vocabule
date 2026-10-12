import Foundation

/// Ce que l'application et le widget affichent pour un instant donné.
///
/// Le même type sert aux deux : c'est ce qui rend impossible une divergence
/// entre l'écran verrouillé et l'écran Aujourd'hui. Si les deux calculaient leur
/// terme chacune de son côté, la moindre différence de règle produirait deux
/// découvertes différentes à la même heure.
public struct TodaySnapshot: Sendable {
    /// Créneau actif : « le dernier commencé », qui reste celui du soir après
    /// minuit jusqu'au créneau du matin.
    public let slot: SlotID
    public let entryID: EntryID?
    public let summary: EntrySummary?
    /// État lu, ou état initial si aucun n'a encore été écrit.
    public let state: UserState
    /// `false` lorsque le widget affiche un terme calculé, sans état persisté.
    ///
    /// L'interface doit le dire : dans ce cas, les actions « Autre mot » et
    /// « Déjà connu » ne peuvent pas être enregistrées, et le prétendre serait
    /// mentir à l'utilisateur.
    public let isPersisted: Bool
    public let exhaustion: CorpusExhaustion?
    /// Date à laquelle le créneau affiché se termine, pour la chronologie du
    /// widget.
    public let refreshAfter: Date?

    public var hasEntry: Bool { entryID != nil }
}

/// Erreur d'une action demandée depuis l'interface ou le widget.
public enum SessionActionError: Error, CustomStringConvertible {
    /// Aucun état persisté : l'action ne peut pas être enregistrée.
    case noPersistedState
    /// Le corpus s'est épuisé entre-temps.
    case exhausted(CorpusExhaustion)

    public var description: String {
        switch self {
        case .noPersistedState:
            return "Aucune découverte enregistrée pour l'instant. Ouvrez Vocabulle une première fois."
        case .exhausted(let exhaustion):
            return exhaustion.message
        }
    }
}

/// Point d'entrée unique de la logique métier, partagé par l'application et par
/// l'extension widget.
///
/// # Pourquoi ce type existe
///
/// Le projet interdit deux magasins privés divergents. Il interdit aussi de
/// charger le corpus entier dans l'extension. Ce type est l'endroit où ces deux
/// contraintes se rencontrent : il lit l'état partagé **en lecture seule**
/// lorsqu'il n'a pas le droit d'écrire, calcule le créneau courant avec la même
/// horloge injectée que les tests, et ne demande au corpus que les fiches
/// nécessaires.
public struct VocabulleSession: Sendable {

    public let container: SharedContainer
    public let corpus: CorpusStore
    public let clock: Clock
    /// Fuseau de l'appareil, injecté pour que rien ne dépende de la machine.
    public let deviceTimeZone: TimeZone

    public init(
        container: SharedContainer,
        corpus: CorpusStore,
        clock: Clock = SystemClock(),
        deviceTimeZone: TimeZone = .current
    ) {
        self.container = container
        self.corpus = corpus
        self.clock = clock
        self.deviceTimeZone = deviceTimeZone
    }

    public var stateStore: UserStateStore {
        UserStateStore(container: container)
    }

    /// Résolveur de créneaux correspondant aux réglages enregistrés.
    public func resolver(for settings: VocabulleSettings) -> SlotResolver {
        SlotResolver(
            schedule: settings.schedule,
            timeZonePolicy: settings.timeZonePolicy,
            deviceTimeZone: deviceTimeZone
        )
    }

    /// Le conteneur est-il réellement partagé avec l'extension ?
    ///
    /// Les réglages l'affichent. Quand il ne l'est pas, le widget reste juste —
    /// il recalcule le tirage nominal — mais il ne peut enregistrer aucune
    /// action de l'utilisateur, et il faut le dire.
    public var isSharedWithWidget: Bool { container.tier == .appGroup }

    // MARK: - Lecture

    /// Charge l'état sans jamais en créer.
    ///
    /// Un état absent n'est pas une erreur : c'est la situation normale d'une
    /// première installation, et celle du widget avant la première ouverture de
    /// l'application. Renvoyer `nil` plutôt qu'un état initial évite que deux
    /// processus n'inventent chacun une graine différente.
    public func loadStateIfPresent() throws -> UserState? {
        guard FileManager.default.fileExists(atPath: container.stateURL.path) else { return nil }
        return try stateStore.load()
    }

    /// Instantané du créneau actif, pour l'écran Aujourd'hui ou pour le widget.
    ///
    /// - Parameter allowNominalFallback: lorsqu'aucun état n'est persisté,
    ///   renvoyer le tirage nominal du créneau au lieu de rien. Le widget
    ///   l'utilise ; l'application, non — elle écrit son état avant d'afficher.
    public func snapshot(now: Date? = nil, allowNominalFallback: Bool = true) throws -> TodaySnapshot {
        let instant = now ?? clock.now
        let state = try loadStateIfPresent() ?? UserState.initial(seed: "", now: instant)
        let resolver = resolver(for: state.settings)
        let slot = resolver.currentSlot(at: instant)
        let engine = SelectionEngine(corpus: corpus, seed: state.selectionSeed)
        let persisted = hasPersistedState

        if persisted {
            let result = try engine.resolve(slot: slot, state: state, now: instant)
            return TodaySnapshot(
                slot: slot,
                entryID: result.assignment?.entryID,
                summary: result.summary,
                state: result.state,
                isPersisted: true,
                exhaustion: result.exhaustion,
                refreshAfter: resolver.endDate(of: slot)
            )
        }

        guard allowNominalFallback else {
            return TodaySnapshot(
                slot: slot,
                entryID: nil,
                summary: nil,
                state: state,
                isPersisted: false,
                exhaustion: nil,
                refreshAfter: resolver.endDate(of: slot)
            )
        }

        let entryID = try engine.nominalEntryID(for: slot)
        return TodaySnapshot(
            slot: slot,
            entryID: entryID,
            summary: try entryID.flatMap { try corpus.summary(withID: $0) },
            state: state,
            isPersisted: false,
            exhaustion: nil,
            refreshAfter: resolver.endDate(of: slot)
        )
    }

    /// Fiche complète d'un terme, pour l'écran Fiche.
    public func entry(withID id: EntryID) throws -> LexicalEntry? {
        try corpus.entry(withID: id)
    }

    // MARK: - Actions

    /// « Autre mot ». Écrit l'état et renvoie le nouvel instantané.
    @discardableResult
    public func replaceTerm(now: Date? = nil) throws -> TodaySnapshot {
        try mutate(now: now) { engine, slot, state, instant in
            let result = try engine.replace(slot: slot, state: state, now: instant)
            if let exhaustion = result.exhaustion, result.assignment == nil {
                throw SessionActionError.exhausted(exhaustion)
            }
            return result.state
        }
    }

    /// « Déjà connu » depuis le créneau courant.
    @discardableResult
    public func markKnown(entryID: EntryID, now: Date? = nil) throws -> TodaySnapshot {
        try mutate(now: now) { engine, slot, state, instant in
            try engine.markKnown(entryID: entryID, slot: slot, state: state, now: instant).state
        }
    }

    /// Bascule un favori. Fonctionne même sans découverte du jour, donc elle ne
    /// passe pas par `mutate` : elle ne dépend pas d'un créneau.
    @discardableResult
    public func toggleFavourite(entryID: EntryID, now: Date? = nil) throws -> UserState {
        guard hasPersistedState else { throw SessionActionError.noPersistedState }
        let instant = now ?? clock.now
        return try stateStore.update(now: instant) { state in
            SelectionEngine(corpus: self.corpus, seed: state.selectionSeed)
                .toggleFavourite(entryID: entryID, state: state)
        }
    }

    /// Enregistre l'ouverture d'une fiche depuis un créneau donné.
    ///
    /// Le créneau est passé explicitement plutôt que recalculé : un lien profond
    /// peut désigner un terme affiché par un widget devenu périmé, et marquer
    /// « consulté » le créneau courant porterait alors sur le mauvais terme.
    @discardableResult
    public func markConsulted(slot: SlotID, now: Date? = nil) throws -> UserState {
        guard hasPersistedState else { throw SessionActionError.noPersistedState }
        let instant = now ?? clock.now
        return try stateStore.update(now: instant) { state in
            SelectionEngine(corpus: self.corpus, seed: state.selectionSeed)
                .markConsulted(slot: slot, state: state)
        }
    }

    /// Annule un « déjà connu ».
    @discardableResult
    public func unmarkKnown(entryID: EntryID, now: Date? = nil) throws -> UserState {
        guard hasPersistedState else { throw SessionActionError.noPersistedState }
        let instant = now ?? clock.now
        return try stateStore.update(now: instant) { state in
            SelectionEngine(corpus: self.corpus, seed: state.selectionSeed)
                .unmarkKnown(entryID: entryID, state: state)
        }
    }

    /// Réserve les créneaux suivants.
    ///
    /// Appelé par l'application après chaque affichage : c'est ce qui garantit
    /// que les trois prochains créneaux ont déjà un terme, et qu'aucun d'eux
    /// n'est identique.
    @discardableResult
    public func planAhead(from slot: SlotID, now: Date? = nil) throws -> UserState {
        guard hasPersistedState else { throw SessionActionError.noPersistedState }
        let instant = now ?? clock.now
        return try stateStore.update(now: instant) { state in
            let engine = SelectionEngine(corpus: self.corpus, seed: state.selectionSeed)
            var working = (try? engine.startNewRoundIfNeeded(state: state, now: instant)) ?? state
            working = (try? engine.planAhead(
                from: slot,
                count: working.settings.plannedAhead,
                state: working,
                now: instant
            )) ?? working
            return working
        }
    }

    /// Écrit une transformation sur le créneau courant.
    private func mutate(
        now: Date?,
        _ transform: (SelectionEngine, SlotID, UserState, Date) throws -> UserState
    ) throws -> TodaySnapshot {
        guard hasPersistedState else { throw SessionActionError.noPersistedState }
        let instant = now ?? clock.now
        var outcome: Result<UserState, Error>?
        _ = try stateStore.update(now: instant) { state in
            let resolver = self.resolver(for: state.settings)
            let slot = resolver.currentSlot(at: instant)
            do {
                let engine = SelectionEngine(corpus: self.corpus, seed: state.selectionSeed)
                let next = try transform(engine, slot, state, instant)
                outcome = .success(next)
                return next
            } catch {
                // La transformation a échoué : on renvoie l'état inchangé, sans
                // quoi l'échec serait enregistré comme une modification.
                outcome = .failure(error)
                return state
            }
        }
        if case .failure(let error) = outcome { throw error }
        return try snapshot(now: instant)
    }

    private var hasPersistedState: Bool {
        FileManager.default.fileExists(atPath: container.stateURL.path)
    }
}
