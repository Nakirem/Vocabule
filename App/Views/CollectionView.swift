import SwiftUI

/// Écran Collection : parcourir, chercher, retrouver ses favoris.
struct CollectionView: View {
    @Environment(AppEnvironment.self) private var environment

    enum Mode: String, CaseIterable, Identifiable {
        case browse
        case favourites
        case known

        var id: String { rawValue }

        var title: String {
            switch self {
            case .browse: return "Tout"
            case .favourites: return "Favoris"
            case .known: return "Déjà connus"
            }
        }
    }

    /// Nombre de fiches chargées par page.
    private static let pageSize = 40

    @State private var mode: Mode = .browse
    @State private var category: EntryCategory?
    @State private var query = ""
    @State private var items: [EntrySummary] = []
    @State private var reachedEnd = false
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modePicker
                if mode == .browse { categoryPicker }
                list
            }
            .background(VocabulleTheme.background)
            .navigationTitle("Collection")
            .searchable(text: $query, prompt: "Chercher un mot, une expression…")
            .onChange(of: mode) { _, _ in reload() }
            .onChange(of: category) { _, _ in reload() }
            .onChange(of: query) { _, _ in reload() }
            .onChange(of: environment.state.knownEntryIDs) { _, _ in
                if mode == .known { reload() }
            }
            .onChange(of: environment.state.favouriteEntryIDs) { _, _ in
                if mode == .favourites { reload() }
            }
            .task { if items.isEmpty { reload() } }
        }
    }

    // MARK: - Filtres

    private var modePicker: some View {
        Picker("Affichage", selection: $mode) {
            ForEach(Mode.allCases) { value in
                Text(value.title).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, VocabulleTheme.Spacing.medium)
        .padding(.top, VocabulleTheme.Spacing.small)
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: VocabulleTheme.Spacing.small) {
                chip(title: "Toutes", isSelected: category == nil) { category = nil }
                ForEach(EntryCategory.allCases, id: \.self) { value in
                    chip(title: value.displayName, isSelected: category == value) { category = value }
                }
            }
            .padding(.horizontal, VocabulleTheme.Spacing.medium)
            .padding(.vertical, VocabulleTheme.Spacing.small)
        }
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(VocabulleTheme.labelFont)
                .foregroundStyle(isSelected ? VocabulleTheme.background : VocabulleTheme.textPrimary)
                .padding(.horizontal, VocabulleTheme.Spacing.medium)
                .padding(.vertical, VocabulleTheme.Spacing.small)
                .background(
                    Capsule().fill(isSelected ? VocabulleTheme.accent : VocabulleTheme.surface)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Liste

    @ViewBuilder
    private var list: some View {
        if items.isEmpty && !isLoading {
            emptyState
        } else {
            List {
                ForEach(items) { summary in
                    Button {
                        environment.presentEntry(id: summary.id)
                    } label: {
                        SummaryRow(summary: summary, isFavourite: environment.isFavourite(summary.id))
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(VocabulleTheme.surface)
                    .onAppear {
                        if summary.id == items.last?.id { loadMore() }
                    }
                }
                if isLoading && !reachedEnd {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(VocabulleTheme.background)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            switch mode {
            case .browse:
                ContentUnavailableView(
                    "Corpus vide",
                    systemImage: "books.vertical",
                    description: Text("Aucune fiche n'est disponible dans cette catégorie.")
                )
            case .favourites:
                ContentUnavailableView(
                    "Aucun favori",
                    systemImage: "star",
                    description: Text("Touchez l'étoile d'une fiche pour la retrouver ici.")
                )
            case .known:
                ContentUnavailableView(
                    "Aucun terme marqué",
                    systemImage: "checkmark.circle",
                    description: Text("Les termes que vous marquez « déjà connu » disparaissent des découvertes et s'affichent ici.")
                )
            }
        }
    }

    // MARK: - Chargement

    private func reload() {
        items = []
        reachedEnd = false
        loadMore()
    }

    private func loadMore() {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }

        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            items = environment.search(query, limit: 100)
            reachedEnd = true
            return
        }

        switch mode {
        case .favourites:
            items = environment.favouriteSummaries()
            reachedEnd = true
        case .known:
            items = environment.knownSummaries()
            reachedEnd = true
        case .browse:
            let page = environment.summaries(
                category: category,
                offset: items.count,
                limit: Self.pageSize
            )
            items.append(contentsOf: page)
            // Une page incomplète signifie qu'il n'y a plus rien à charger.
            if page.count < Self.pageSize { reachedEnd = true }
        }
    }
}

/// Ligne de liste d'une fiche.
struct SummaryRow: View {
    let summary: EntrySummary
    let isFavourite: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: VocabulleTheme.Spacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: VocabulleTheme.Spacing.small) {
                Text(summary.term)
                    .font(VocabulleTheme.termFont(for: .headline))
                    .foregroundStyle(VocabulleTheme.textPrimary)
                if isFavourite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(VocabulleTheme.accent)
                        .accessibilityLabel("Favori")
                }
                Spacer(minLength: 0)
                if let label = summary.compactGrammar {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(VocabulleTheme.textTertiary)
                }
            }
            Text(summary.shortDefinition)
                .font(.footnote)
                .foregroundStyle(VocabulleTheme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, VocabulleTheme.Spacing.tight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
