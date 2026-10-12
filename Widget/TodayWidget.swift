import SwiftUI
import WidgetKit

/// Une ligne de la chronologie du widget.
struct TodayEntry: TimelineEntry {
    let date: Date
    /// Forme textuelle du créneau (`2026-10-12#morning`), transmise aux
    /// intentions pour qu'elles sachent quel créneau elles visent.
    let slotKey: String
    let periodName: String
    let periodSymbol: String
    let entryID: String?
    let term: String?
    let definition: String?
    let registerLabel: String?
    let registerWarning: Bool
    /// `true` lorsque le conteneur partagé existe : les boutons d'action ne
    /// sont proposés que dans ce cas.
    let canAct: Bool
    let message: String?
    let deepLink: URL?

    var isEmpty: Bool { term == nil }
}

/// Chronologie du widget.
///
/// # Pourquoi une entrée par créneau plutôt qu'un rafraîchissement fréquent
///
/// WidgetKit limite le nombre de rechargements qu'une application peut
/// demander. On construit donc d'avance une entrée pour chaque début de
/// créneau : l'écran verrouillé change de mot à l'heure prévue **sans** que
/// l'application ait à intervenir, même si iOS n'accorde aucun rechargement.
/// C'est aussi ce qui fait tenir l'exigence « le mot du soir reste affiché après
/// minuit » : la chronologie ne comporte aucune entrée à minuit, donc rien ne
/// change avant le créneau du matin.
struct TodayProvider: TimelineProvider {

    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(
            date: Date(),
            slotKey: "2026-01-01#morning",
            periodName: "Matin",
            periodSymbol: "sunrise",
            entryID: "monomaniaque",
            term: "Monomaniaque",
            definition: "Qui ne s'intéresse qu'à une seule chose, au point d'en oublier le reste.",
            registerLabel: nil,
            registerWarning: false,
            canAct: false,
            message: nil,
            deepLink: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(makeEntries(count: 1).first ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date()
        let entries = makeEntries(count: Self.lookaheadSlots)
        // Le rafraîchissement est demandé après la dernière entrée connue : iOS
        // reste libre de l'accorder ou non, et la chronologie suffit jusque-là.
        let refresh = entries.last?.date.addingTimeInterval(60) ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }

    /// Nombre de créneaux préparés d'avance.
    private static let lookaheadSlots = 3

    private func makeEntries(count: Int) -> [TodayEntry] {
        let now = Date()
        let container = SharedContainer.resolve()
        let state = try? UserStateStore(container: container).load()
        let settings = state?.settings ?? .default
        let resolver = SlotResolver(
            schedule: settings.schedule,
            timeZonePolicy: settings.timeZonePolicy
        )

        guard let corpus = try? EmbeddedCorpus.open() else {
            let slot = resolver.currentSlot(at: now)
            return [message(
                "Le corpus de Vocabulle est inaccessible. Ouvrez l'application pour le signaler.",
                at: now,
                period: slot.period,
                slotKey: slot.description
            )]
        }

        var dates = [now]
        dates.append(contentsOf: resolver.upcomingStartDates(after: now, count: max(0, count - 1)))

        return dates.map { date in
            makeEntry(
                at: date,
                container: container,
                corpus: corpus,
                state: state,
                resolver: resolver
            )
        }
    }

    private func makeEntry(
        at date: Date,
        container: SharedContainer,
        corpus: SQLiteCorpusStore,
        state: UserState?,
        resolver: SlotResolver
    ) -> TodayEntry {
        let slot = resolver.currentSlot(at: date)
        let canAct = container.tier == .appGroup && state != nil

        // Sans état persisté — première installation, ou widget consulté avant
        // la première ouverture de l'application — on affiche le tirage nominal
        // du créneau. Il ne dépend d'aucun état utilisateur, donc le widget
        // reste exact même sans conteneur partagé.
        let engine = SelectionEngine(corpus: corpus, seed: state?.selectionSeed ?? "")
        var entryID: EntryID?
        var summary: EntrySummary?
        var exhaustion: CorpusExhaustion?

        if let state {
            let result = try? engine.resolve(slot: slot, state: state, now: date)
            entryID = result?.assignment?.entryID
            summary = result?.summary
            exhaustion = result?.exhaustion
        } else {
            entryID = try? engine.nominalEntryID(for: slot)
            summary = entryID.flatMap { try? corpus.summary(withID: $0) }
        }

        guard let summary, let entryID else {
            let text = exhaustion?.message
                ?? "Aucune découverte n'est disponible pour ce créneau."
            return message(text, at: date, period: slot.period, slotKey: slot.description)
        }

        return TodayEntry(
            date: date,
            slotKey: slot.description,
            periodName: slot.period.displayName,
            periodSymbol: slot.period.symbolName,
            entryID: entryID.rawValue,
            term: summary.term,
            definition: summary.shortDefinition,
            registerLabel: summary.registerLabel,
            registerWarning: summary.registerWarning,
            canAct: canAct,
            message: nil,
            deepLink: DeepLink.url(for: entryID)
        )
    }

    private func message(
        _ text: String,
        at date: Date,
        period: DayPeriod,
        slotKey: String
    ) -> TodayEntry {
        TodayEntry(
            date: date,
            slotKey: slotKey,
            periodName: period.displayName,
            periodSymbol: period.symbolName,
            entryID: nil,
            term: nil,
            definition: text,
            registerLabel: nil,
            registerWarning: false,
            canAct: false,
            message: text,
            deepLink: nil
        )
    }
}

/// Le widget d'écran verrouillé.
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: vocabulleWidgetKind, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Découverte du moment")
        .description("Le terme en cours et sa définition courte, directement sur l'écran verrouillé.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .systemSmall])
    }
}

/// Contenu du widget, adapté à la famille demandée.
struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    var body: some View {
        content
            // Le lien porte l'identifiant de la fiche, jamais « le terme
            // courant » : toucher un widget périmé ouvre malgré tout le terme
            // qui était réellement affiché.
            .widgetURL(entry.deepLink)
            .containerBackground(for: .widget) {
                switch family {
                case .accessoryRectangular, .accessoryInline:
                    AccessoryWidgetBackground()
                default:
                    VocabulleTheme.background
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            inlineContent
        case .accessoryRectangular:
            rectangularContent
        default:
            smallContent
        }
    }

    // MARK: - Écran verrouillé, format en ligne

    private var inlineContent: some View {
        // Une seule ligne : le terme, ou rien du tout. Aucune place pour une
        // définition tronquée qui ne voudrait rien dire.
        Text(entry.term ?? entry.message ?? "Vocabulle")
            .accessibilityLabel(accessibilityText)
    }

    // MARK: - Écran verrouillé, format rectangulaire

    private var rectangularContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: entry.periodSymbol)
                    .font(.caption2)
                    .accessibilityHidden(true)
                Text(entry.term ?? entry.periodName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if entry.registerWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .accessibilityLabel("Registre à employer avec discernement")
                }
            }

            if let definition = entry.definition {
                Text(definition)
                    .font(.caption2)
                    .lineLimit(entry.canAct ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if entry.canAct, let entryID = entry.entryID {
                HStack(spacing: 10) {
                    Button(intent: ReplaceTermIntent(slotKey: entry.slotKey, shownEntryID: entryID)) {
                        Label("Autre mot", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityLabel("Autre mot")

                    Button(intent: MarkKnownIntent(slotKey: entry.slotKey, shownEntryID: entryID)) {
                        Label("Déjà connu", systemImage: "checkmark.circle")
                    }
                    .accessibilityLabel("Déjà connu")
                }
                .font(.caption2)
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Écran d'accueil, petit format

    private var smallContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(entry.periodName, systemImage: entry.periodSymbol)
                .font(.caption2)
                .foregroundStyle(VocabulleTheme.textSecondary)

            if let term = entry.term {
                Text(term)
                    .font(VocabulleTheme.termFont(for: .headline))
                    .foregroundStyle(VocabulleTheme.textPrimary)
                    .lineLimit(2)
                if let definition = entry.definition {
                    Text(definition)
                        .font(.caption2)
                        .foregroundStyle(VocabulleTheme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(entry.message ?? "Aucune découverte")
                    .font(.caption2)
                    .foregroundStyle(VocabulleTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var accessibilityText: String {
        guard let term = entry.term else { return entry.message ?? "Vocabulle" }
        let definition = entry.definition ?? ""
        return "\(entry.periodName) : \(term). \(definition)"
    }
}
