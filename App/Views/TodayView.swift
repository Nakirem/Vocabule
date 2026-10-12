import SwiftUI

/// Écran Aujourd'hui : la découverte du créneau en cours.
struct TodayView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VocabulleTheme.Spacing.large) {
                    if let notice = environment.notice {
                        NoticeBanner(text: notice) { environment.dismissNotice() }
                    }
                    header
                    discovery
                    actions
                    footer
                }
                .padding(VocabulleTheme.Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(VocabulleTheme.background)
            .navigationTitle("Aujourd'hui")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - En-tête

    @ViewBuilder
    private var header: some View {
        if let snapshot = environment.snapshot {
            VStack(alignment: .leading, spacing: VocabulleTheme.Spacing.tight) {
                Text(
                    FrenchFormat.day(Date(), timeZone: environment.activeTimeZone).capitalizedFirst
                )
                .font(.subheadline)
                .foregroundStyle(VocabulleTheme.textSecondary)

                Label(snapshot.slot.period.displayName, systemImage: snapshot.slot.period.symbolName)
                    .font(VocabulleTheme.termFont(for: .title2))
                    .foregroundStyle(VocabulleTheme.textPrimary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Découverte

    @ViewBuilder
    private var discovery: some View {
        if let summary = environment.snapshot?.summary {
            VStack(alignment: .leading, spacing: VocabulleTheme.Spacing.medium) {
                Text(summary.term)
                    .font(VocabulleTheme.termFont(for: .largeTitle))
                    .foregroundStyle(VocabulleTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let label = summary.compactGrammar {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(VocabulleTheme.textSecondary)
                }

                if let register = summary.registerLabel {
                    RegisterChip(label: register, isCaution: summary.registerWarning)
                }

                Text(summary.shortDefinition)
                    .font(VocabulleTheme.definitionFont)
                    .foregroundStyle(VocabulleTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(VocabulleTheme.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: VocabulleTheme.Radius.card, style: .continuous)
                    .fill(VocabulleTheme.surface)
            )
            .accessibilityElement(children: .combine)
        } else if let exhaustion = environment.snapshot?.exhaustion {
            ExhaustionCard(exhaustion: exhaustion)
        } else {
            ContentUnavailableView(
                "Aucune découverte",
                systemImage: "sparkles",
                description: Text("Le corpus ne contient aucun terme disponible pour ce créneau.")
            )
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        if let entryID = environment.snapshot?.entryID {
            VStack(spacing: VocabulleTheme.Spacing.small) {
                Button {
                    environment.presentEntry(id: entryID)
                } label: {
                    Label("Lire la fiche complète", systemImage: "text.book.closed")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(VocabulleTheme.accent)

                HStack(spacing: VocabulleTheme.Spacing.small) {
                    Button {
                        environment.replaceCurrentTerm()
                    } label: {
                        Label("Autre mot", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        environment.markCurrentTermAsKnown()
                    } label: {
                        Label("Déjà connu", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    environment.toggleFavourite(entryID)
                } label: {
                    Label(
                        environment.isFavourite(entryID) ? "Retirer des favoris" : "Ajouter aux favoris",
                        systemImage: environment.isFavourite(entryID) ? "star.fill" : "star"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(VocabulleTheme.accent)
            }
        }
    }

    // MARK: - Pied de page

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: VocabulleTheme.Spacing.small) {
            if let next = environment.snapshot?.refreshAfter {
                Label(
                    "Prochaine découverte à \(FrenchFormat.clock(next, timeZone: environment.activeTimeZone))",
                    systemImage: "clock"
                )
                .font(.footnote)
                .foregroundStyle(VocabulleTheme.textSecondary)
            }
            // L'absence de conteneur partagé change ce que le widget peut
            // faire. Le dire ici évite que l'utilisateur croie à un bogue.
            if !environment.isSharedWithWidget {
                Label(
                    "Le widget n'a pas accès à vos personnalisations : il affiche le terme prévu pour le créneau.",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(VocabulleTheme.textTertiary)
            }
        }
    }
}

/// Bandeau d'information ou d'erreur, refermable.
struct NoticeBanner: View {
    let text: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: VocabulleTheme.Spacing.small) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(VocabulleTheme.caution)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(VocabulleTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Masquer le message")
            }
        }
        .padding(VocabulleTheme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: VocabulleTheme.Radius.card, style: .continuous)
                .fill(VocabulleTheme.caution.opacity(0.12))
        )
    }
}

/// Message affiché lorsque tout le corpus a été parcouru.
struct ExhaustionCard: View {
    let exhaustion: CorpusExhaustion

    var body: some View {
        VStack(alignment: .leading, spacing: VocabulleTheme.Spacing.small) {
            Label("Corpus parcouru en entier", systemImage: "checkmark.seal")
                .font(VocabulleTheme.termFont(for: .headline))
                .foregroundStyle(VocabulleTheme.textPrimary)
            Text(exhaustion.message)
                .font(VocabulleTheme.definitionFont)
                .foregroundStyle(VocabulleTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(exhaustion.totalEntries) termes au corpus, \(exhaustion.knownEntries) marqués comme connus.")
                .font(.footnote)
                .foregroundStyle(VocabulleTheme.textTertiary)
        }
        .padding(VocabulleTheme.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: VocabulleTheme.Radius.card, style: .continuous)
                .fill(VocabulleTheme.surface)
        )
    }
}

extension String {
    /// « mardi 13 octobre » → « Mardi 13 octobre ».
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
