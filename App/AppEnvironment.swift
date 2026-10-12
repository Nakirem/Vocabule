import Foundation
import Observation
import UserNotifications
import WidgetKit

/// État observable de l'application.
///
/// # Pourquoi un objet et non des vues qui calculent
///
/// Toutes les vues passent par ici, et aucune ne parle directement au corpus ni
/// au fichier d'état. La raison n'est pas l'élégance : c'est que chaque action
/// doit produire **le même effet** quel que soit l'écran qui la déclenche, et
/// que le widget doit être prévenu du changement. Centraliser évite qu'un écran
/// oublie l'un des deux.
@MainActor
@Observable
final class AppEnvironment {

    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var snapshot: TodaySnapshot?
    private(set) var metadata: CorpusMetadata?
    /// Message affiché en bandeau : erreur d'écriture, corpus épuisé, terme
    /// disparu. Jamais avalé en silence.
    private(set) var notice: String?
    /// État de l'autorisation de notification, pour que l'interrupteur des
    /// réglages reflète la réalité système et pas seulement l'intention.
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined

    /// Fiche ouverte en feuille modale. `nil` ferme la feuille.
    var presentedEntry: LexicalEntry?
    var selectedTab: Int = 0

    private(set) var session: VocabulleSession?
    private let notifications = NotificationScheduler()

    init() {
        let container = SharedContainer.resolve()
        do {
            let corpus = try EmbeddedCorpus.open()
            session = VocabulleSession(container: container, corpus: corpus)
        } catch {
            session = nil
            phase = .failed(String(describing: error))
        }
    }

    // MARK: - Lecture

    var state: UserState {
        snapshot?.state ?? UserState.initial(seed: "", now: Date())
    }

    var settings: VocabulleSettings { state.settings }
    var isSharedWithWidget: Bool { session?.isSharedWithWidget ?? false }
    var containerTier: SharedContainerTier { session?.container.tier ?? .isolated }
    var attemptedGroupIdentifiers: [String] {
        session?.container.attemptedGroupIdentifiers ?? []
    }

    /// Fuseau effectif des réglages, pour afficher des heures justes.
    var activeTimeZone: TimeZone {
        session?.resolver(for: settings).timeZone ?? .current
    }

    // MARK: - Cycle de vie

    /// Première lecture : crée l'état s'il n'existe pas, puis résout et réserve.
    func bootstrap() {
        guard let session else { return }
        do {
            let now = Date()
            if !FileManager.default.fileExists(atPath: session.container.stateURL.path) {
                // La graine est tirée une fois pour toutes puis recopiée à
                // chaque écriture. Elle n'est dérivée ni de l'appareil ni d'un
                // hachage d'exécution : AltStore change les identifiants de
                // bundle à chaque re-signature, et le tirage doit survivre.
                let initial = UserState.initial(seed: UUID().uuidString, now: now)
                _ = try session.stateStore.save(initial, now: now)
            }
            metadata = try? session.corpus.metadata()
            phase = .ready
            try reload(planning: true)
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// Relit l'état et le créneau courant. Appelé au retour au premier plan.
    func refresh() {
        do {
            try reload(planning: false)
        } catch {
            notice = String(describing: error)
        }
    }

    private func reload(planning: Bool) throws {
        guard let session else { return }
        snapshot = try session.snapshot()
        guard planning, let current = snapshot else { return }
        // Réserver les créneaux suivants dès maintenant : c'est ce qui garantit
        // qu'aucune des trois prochaines découvertes n'est identique, et que le
        // widget connaît déjà son terme avant l'heure.
        _ = try? session.planAhead(from: current.slot)
        snapshot = try session.snapshot()
    }

    func dismissNotice() {
        notice = nil
    }

    // MARK: - Actions sur la découverte

    func replaceCurrentTerm() {
        guard let session else { return }
        do {
            snapshot = try session.replaceTerm()
            notice = nil
            refreshWidgets()
        } catch {
            notice = String(describing: error)
        }
    }

    func markCurrentTermAsKnown() {
        guard let session, let entryID = snapshot?.entryID else { return }
        do {
            snapshot = try session.markKnown(entryID: entryID)
            notice = nil
            refreshWidgets()
        } catch {
            notice = String(describing: error)
        }
    }

    func unmarkKnown(_ entryID: EntryID) {
        guard let session else { return }
        do {
            _ = try session.unmarkKnown(entryID: entryID)
            notice = nil
            refresh()
            refreshWidgets()
        } catch {
            notice = String(describing: error)
        }
    }

    func toggleFavourite(_ entryID: EntryID) {
        guard let session else { return }
        do {
            _ = try session.toggleFavourite(entryID: entryID)
            notice = nil
            refresh()
            refreshWidgets()
        } catch {
            notice = String(describing: error)
        }
    }

    func isFavourite(_ entryID: EntryID) -> Bool {
        state.favouriteEntryIDs.contains(entryID)
    }

    // MARK: - Ouverture d'une fiche

    /// Charge une fiche complète, sans effet de bord.
    func loadEntry(id: EntryID) -> LexicalEntry? {
        try? session?.entry(withID: id)
    }

    func presentEntry(id: EntryID) {
        guard let session else { return }
        do {
            guard let entry = try session.entry(withID: id) else {
                notice = "Ce terme ne figure plus dans le corpus."
                return
            }
            // On marque « consulté » le créneau qui affichait réellement ce
            // terme, pas le créneau courant : un lien profond peut venir d'un
            // widget périmé, et attribuer la consultation au mauvais créneau
            // fausserait l'historique.
            if let slot = slotDisplaying(id) {
                _ = try? session.markConsulted(slot: slot)
            }
            presentedEntry = entry
            refresh()
        } catch {
            notice = String(describing: error)
        }
    }

    private func slotDisplaying(_ entryID: EntryID) -> SlotID? {
        state.assignments
            .compactMap { key, assignment -> SlotID? in
                guard assignment.entryID == entryID else { return nil }
                return SlotID(parsing: key)
            }
            .sorted()
            .last
    }

    func handle(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        switch link {
        case .today:
            presentedEntry = nil
            selectedTab = 0
        case .entry(let id):
            selectedTab = 0
            presentEntry(id: id)
        }
    }

    // MARK: - Réglages

    func updateSchedule(_ schedule: SlotSchedule) {
        applySettings { $0.schedule = schedule.normalized() }
        Task { await syncNotifications() }
    }

    func updateTimeZonePolicy(_ policy: TimeZonePolicy) {
        applySettings { $0.timeZonePolicy = policy }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        Task {
            if enabled {
                let granted = await notifications.requestAuthorization()
                if granted {
                    applySettings { $0.notificationsEnabled = true }
                    await notifications.schedule(state.settings.schedule)
                } else {
                    applySettings { $0.notificationsEnabled = false }
                }
            } else {
                await notifications.cancelAll()
                applySettings { $0.notificationsEnabled = false }
            }
            await syncNotifications()
        }
    }

    /// Aligne les rappels programmés sur les réglages, et relève l'état réel de
    /// l'autorisation auprès du système.
    func syncNotifications() async {
        notificationStatus = await notifications.authorizationStatus()
        guard state.settings.notificationsEnabled,
              notificationStatus == .authorized
        else { return }
        await notifications.schedule(state.settings.schedule)
    }

    func completeOnboarding() {
        guard let session else { return }
        do {
            _ = try session.stateStore.update(now: Date()) { state in
                var copy = state
                copy.hasCompletedOnboarding = true
                return copy
            }
            refresh()
        } catch {
            notice = String(describing: error)
        }
    }

    private func applySettings(_ transform: (inout VocabulleSettings) -> Void) {
        guard let session else { return }
        do {
            _ = try session.stateStore.update(now: Date()) { state in
                var copy = state
                transform(&copy.settings)
                return copy
            }
            notice = nil
            refresh()
            refreshWidgets()
        } catch {
            notice = String(describing: error)
        }
    }

    // MARK: - Collection

    func summaries(category: EntryCategory?, offset: Int, limit: Int) -> [EntrySummary] {
        guard let session else { return [] }
        return (try? session.corpus.summaries(category: category, limit: limit, offset: offset)) ?? []
    }

    func search(_ query: String, limit: Int = 50) -> [EntrySummary] {
        guard let session, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return (try? session.corpus.search(query, limit: limit)) ?? []
    }

    func favouriteSummaries() -> [EntrySummary] {
        summaries(for: state.favouriteEntryIDs)
    }

    func knownSummaries() -> [EntrySummary] {
        summaries(for: state.knownEntryIDs)
    }

    private func summaries(for ids: Set<EntryID>) -> [EntrySummary] {
        guard let session, !ids.isEmpty else { return [] }
        let found = (try? session.corpus.summaries(withIDs: ids.sorted())) ?? []
        return found.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
    }

    private func refreshWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
