import SwiftUI

@main
struct VocabulleApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .task { environment.bootstrap() }
                .task { await environment.syncNotifications() }
                .onOpenURL { environment.handle($0) }
        }
    }
}

/// Aiguillage de premier niveau.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            switch environment.phase {
            case .loading:
                LaunchView()
            case .failed(let message):
                CorpusFailureView(message: message)
            case .ready:
                if environment.state.hasCompletedOnboarding {
                    MainTabs()
                } else {
                    OnboardingView()
                }
            }
        }
        .background(VocabulleTheme.background)
    }
}

private struct LaunchView: View {
    var body: some View {
        VStack(spacing: VocabulleTheme.Spacing.medium) {
            ProgressView()
            Text("Préparation de votre première découverte…")
                .font(VocabulleTheme.bodyFont)
                .foregroundStyle(VocabulleTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(VocabulleTheme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Affiché lorsque le corpus embarqué est absent ou illisible.
///
/// On ne masque jamais ce cas derrière un écran vide : un corpus manquant est un
/// défaut de fabrication du binaire, et l'utilisateur doit pouvoir le rapporter
/// avec le message exact plutôt que de croire à un bogue d'affichage.
private struct CorpusFailureView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: VocabulleTheme.Spacing.medium) {
            Image(systemName: "books.vertical")
                .font(.largeTitle)
                .foregroundStyle(VocabulleTheme.caution)
                .accessibilityHidden(true)
            Text("Le corpus est inaccessible")
                .font(VocabulleTheme.termFont(for: .title2))
                .foregroundStyle(VocabulleTheme.textPrimary)
            Text("Vocabulle ne peut pas ouvrir sa base de termes. Réinstallez l'application ; si le problème persiste, signalez le message ci-dessous.")
                .font(VocabulleTheme.bodyFont)
                .foregroundStyle(VocabulleTheme.textSecondary)
            Text(message)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(VocabulleTheme.textTertiary)
                .textSelection(.enabled)
                .padding(VocabulleTheme.Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: VocabulleTheme.Radius.card, style: .continuous)
                        .fill(VocabulleTheme.surface)
                )
        }
        .padding(VocabulleTheme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Les trois onglets de l'application.
struct MainTabs: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var environment = environment

        TabView(selection: $environment.selectedTab) {
            TodayView()
                .tabItem { Label("Aujourd'hui", systemImage: "sparkles") }
                .tag(0)

            CollectionView()
                .tabItem { Label("Collection", systemImage: "books.vertical") }
                .tag(1)

            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape") }
                .tag(2)
        }
        .tint(VocabulleTheme.accent)
        .sheet(item: $environment.presentedEntry) { entry in
            EntrySheet(entry: entry)
        }
    }
}

/// Feuille modale contenant la fiche et sa pile de navigation.
///
/// Chaque terme associé est cliquable et empile une nouvelle fiche : c'est ce
/// qui transforme une découverte isolée en exploration.
struct EntrySheet: View {
    @Environment(\.dismiss) private var dismiss

    let entry: LexicalEntry

    @State private var path: [EntryID] = []

    var body: some View {
        NavigationStack(path: $path) {
            EntryDetailView(entry: entry) { target in
                path.append(target)
            }
            .navigationDestination(for: EntryID.self) { identifier in
                EntryLoaderView(entryID: identifier) { loaded in
                    EntryDetailView(entry: loaded) { target in
                        path.append(target)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}

/// Charge une fiche à la demande, en affichant un état d'attente puis une erreur
/// explicite si le terme a disparu du corpus.
struct EntryLoaderView<Content: View>: View {
    @Environment(AppEnvironment.self) private var environment

    let entryID: EntryID
    @ViewBuilder let content: (LexicalEntry) -> Content

    @State private var entry: LexicalEntry?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let entry {
                content(entry)
            } else if didLoad {
                ContentUnavailableView(
                    "Terme introuvable",
                    systemImage: "questionmark.circle",
                    description: Text("Cette fiche ne figure plus dans le corpus embarqué.")
                )
            } else {
                ProgressView()
            }
        }
        .task(id: entryID) {
            guard !didLoad else { return }
            entry = environment.loadEntry(id: entryID)
            didLoad = true
        }
    }
}
