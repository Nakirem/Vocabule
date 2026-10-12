import AppIntents
import Foundation
import WidgetKit

/// Identifiant du widget, partagé par le bundle, la chronologie et les
/// rechargements ciblés.
let vocabulleWidgetKind = "VocabulleTodayWidget"

/// « Autre mot » depuis l'écran verrouillé.
///
/// # Le piège que cette intention évite
///
/// Un widget peut être périmé : l'utilisateur touche un bouton alors que le
/// créneau a changé et que le widget affiche encore le terme précédent. Sans
/// garde, l'action remplacerait le terme **du créneau courant** — un terme que
/// l'utilisateur n'a jamais vu. L'intention transporte donc l'identifiant du
/// terme réellement affiché, et refuse d'agir s'il ne correspond plus.
///
/// Le refus est silencieux et sans effet : ne rien faire est le comportement
/// juste, remplacer le mauvais terme serait le défaut.
struct ReplaceTermIntent: AppIntent {
    static let title: LocalizedStringResource = "Autre mot"
    static let description = IntentDescription("Remplace la découverte affichée par une autre.")
    /// L'action se produit dans le widget : ouvrir l'application serait une
    /// surprise désagréable pour un simple appui sur un bouton.
    static let openAppWhenRun: Bool = false
    /// Ces intentions ne servent qu'au widget : les exposer dans Raccourcis
    /// laisserait croire qu'elles ont un sens hors contexte.
    static let isDiscoverable: Bool = false

    @Parameter(title: "Créneau")
    var slotKey: String

    @Parameter(title: "Terme affiché")
    var shownEntryID: String

    init() {}

    init(slotKey: String, shownEntryID: String) {
        self.slotKey = slotKey
        self.shownEntryID = shownEntryID
    }

    func perform() async throws -> some IntentResult {
        let expected = EntryID(shownEntryID)
        guard let slot = SlotID(parsing: slotKey),
              let corpus = try? EmbeddedCorpus.open()
        else { return .result() }

        let store = UserStateStore(container: SharedContainer.resolve())
        guard let state = try? store.load() else { return .result() }
        // Le widget n'a rien à remplacer s'il n'a pas de conteneur partagé :
        // écrire dans un magasin privé créerait l'état divergent que le projet
        // interdit.
        guard state[slot]?.entryID == expected else { return .result() }

        let engine = SelectionEngine(corpus: corpus, seed: state.selectionSeed)
        _ = try? store.update(now: Date()) { current in
            // Revérification sous verrou : entre la lecture et l'écriture, un
            // autre processus a pu changer l'état.
            guard current[slot]?.entryID == expected else { return current }
            return (try? engine.replace(slot: slot, state: current, now: Date()).state) ?? current
        }
        WidgetCenter.shared.reloadTimelines(ofKind: vocabulleWidgetKind)
        return .result()
    }
}

/// « Déjà connu » depuis l'écran verrouillé.
///
/// Cette intention n'a pas besoin de la même garde que le remplacement : le
/// moteur de sélection vérifie lui-même que le terme marqué occupe bien le
/// créneau visé avant de le remplacer, et se contente d'enregistrer le marquage
/// sinon. Marquer un terme comme connu reste juste même si le widget est périmé.
struct MarkKnownIntent: AppIntent {
    static let title: LocalizedStringResource = "Déjà connu"
    static let description = IntentDescription("Écarte ce terme des prochaines découvertes.")
    static let openAppWhenRun: Bool = false
    static let isDiscoverable: Bool = false

    @Parameter(title: "Créneau")
    var slotKey: String

    @Parameter(title: "Terme affiché")
    var shownEntryID: String

    init() {}

    init(slotKey: String, shownEntryID: String) {
        self.slotKey = slotKey
        self.shownEntryID = shownEntryID
    }

    func perform() async throws -> some IntentResult {
        let entryID = EntryID(shownEntryID)
        guard let slot = SlotID(parsing: slotKey),
              let corpus = try? EmbeddedCorpus.open()
        else { return .result() }

        let store = UserStateStore(container: SharedContainer.resolve())
        guard let state = try? store.load() else { return .result() }

        let engine = SelectionEngine(corpus: corpus, seed: state.selectionSeed)
        _ = try? store.update(now: Date()) { current in
            (try? engine.markKnown(
                entryID: entryID,
                slot: slot,
                state: current,
                now: Date()
            ).state) ?? current
        }
        WidgetCenter.shared.reloadTimelines(ofKind: vocabulleWidgetKind)
        return .result()
    }
}
