import SwiftUI

/// Fiche détaillée d'un terme.
///
/// Chaque section affiche sa provenance. Ce n'est pas un ornement : les textes
/// repris du Wiktionnaire sont sous CC BY-SA et doivent être attribués, tandis
/// que les textes rédigés pour Vocabulle ne doivent **pas** être présentés comme
/// venant d'une source. Une section absente reste absente — on ne la remplace
/// jamais par une anecdote plausible.
struct EntryDetailView: View {
    @Environment(AppEnvironment.self) private var environment

    let entry: LexicalEntry
    let onSelect: (EntryID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VocabulleTheme.Spacing.large) {
                title
                if !entry.warnedRegisters.isEmpty { registerWarning }
                definitions
                usage
                examples
                etymologyAndHistory
                relations
                sources
            }
            .padding(VocabulleTheme.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(VocabulleTheme.background)
        .navigationTitle(entry.term)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    environment.toggleFavourite(entry.id)
                } label: {
                    Image(systemName: environment.isFavourite(entry.id) ? "star.fill" : "star")
                }
                .accessibilityLabel(
                    environment.isFavourite(entry.id) ? "Retirer des favoris" : "Ajouter aux favoris"
                )
            }
        }
    }

    // MARK: - Titre

    private var title: some View {
        VStack(alignment: .leading, spacing: VocabulleTheme.Spacing.small) {
            Text(entry.term)
                .font(VocabulleTheme.termFont(for: .largeTitle))
                .foregroundStyle(VocabulleTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: VocabulleTheme.Spacing.small) {
                Text(entry.kind.displayName)
                    .font(VocabulleTheme.labelFont)
                    .foregroundStyle(VocabulleTheme.accent)
                if let label = entry.grammar.compactLabel {
                    Text(label)
                        .font(VocabulleTheme.labelFont)
                        .foregroundStyle(VocabulleTheme.textSecondary)
                }
            }

            if let ipa = entry.grammar.ipa, !ipa.isEmpty {
                Text("[\(ipa)]")
                    .font(.callout)
                    .foregroundStyle(VocabulleTheme.textSecondary)
                    .accessibilityLabel("Prononciation : \(ipa)")
            }

            if !entry.registers.isEmpty {
                HStack(spacing: VocabulleTheme.Spacing.tight) {
                    ForEach(entry.registers, id: \.self) { register in
                        RegisterChip(label: register.displayName, isCaution: register.needsWarning)
                    }
                }
            }
        }
    }

    /// Avertissement explicite sur les registres qui peuvent induire en erreur.
    private var registerWarning: some View {
        NoticeBanner(
            text: "À employer avec discernement : "
                + entry.warnedRegisters.map(\.displayName).joined(separator: ", ").lowercased()
                + ". Le contexte d'emploi compte autant que le sens."
        )
    }

    // MARK: - Définitions

    private var definitions: some View {
        VStack(alignment: .leading, spacing: VocabulleTheme.Spacing.medium) {
            SectionCard(title: "Définition") {
                Text(entry.shortDefinition.value)
                    .font(VocabulleTheme.termFont(for: .title3))
                    .foregroundStyle(VocabulleTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ProvenanceLabel(provenance: entry.shortDefinition.provenance)
            }
            SectionCard(title: "Pour aller plus loin") {
                Text(entry.longDefinition.value)
                    .font(VocabulleTheme.definitionFont)
                    .foregroundStyle(VocabulleTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ProvenanceLabel(provenance: entry.longDefinition.provenance)
            }
        }
    }

    // MARK: - Emploi

    @ViewBuilder
    private var usage: some View {
        if let usage = entry.usageNote, !usage.isEmpty {
            SectionCard(title: "Quand l'utiliser ?") {
                Text(usage.value)
                    .font(VocabulleTheme.definitionFont)
                    .foregroundStyle(VocabulleTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ProvenanceLabel(provenance: usage.provenance)
            }
        }
    }

    // MARK: - Exemples

    @ViewBuilder
    private var examples: some View {
        if !entry.examples.isEmpty {
            SectionCard(title: entry.examples.count == 1 ? "Exemple" : "Exemples") {
                ForEach(Array(entry.examples.enumerated()), id: \.offset) { _, example in
                    VStack(alignment: .leading, spacing: VocabulleTheme.Spacing.tight) {
                        Text(example.text)
                            .font(VocabulleTheme.definitionFont)
                            .italic()
                            .foregroundStyle(VocabulleTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !example.creditLine.isEmpty {
                            Text(example.creditLine)
                                .font(.caption)
                                .foregroundStyle(VocabulleTheme.textTertiary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Étymologie et histoire

    @ViewBuilder
    private var etymologyAndHistory: some View {
        if let etymology = entry.etymology, !etymology.isEmpty {
            SectionCard(title: "Étymologie") {
                Text(etymology.value)
                    .font(VocabulleTheme.definitionFont)
                    .foregroundStyle(VocabulleTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ProvenanceLabel(provenance: etymology.provenance)
            }
        }
        if let history = entry.history, !history.isEmpty {
            SectionCard(title: "Histoire") {
                Text(history.value)
                    .font(VocabulleTheme.definitionFont)
                    .foregroundStyle(VocabulleTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ProvenanceLabel(provenance: history.provenance)
            }
        }
    }

    // MARK: - Termes associés

    @ViewBuilder
    private var relations: some View {
        if !entry.relations.isEmpty {
            SectionCard(title: "Termes associés") {
                ForEach(entry.relations, id: \.targetID) { relation in
                    Button {
                        onSelect(relation.targetID)
                    } label: {
                        VStack(alignment: .leading, spacing: VocabulleTheme.Spacing.tight) {
                            HStack(spacing: VocabulleTheme.Spacing.small) {
                                Text(relation.targetTerm)
                                    .font(VocabulleTheme.termFont(for: .headline))
                                    .foregroundStyle(VocabulleTheme.accent)
                                Text(relation.type.displayName)
                                    .font(.caption)
                                    .foregroundStyle(VocabulleTheme.textTertiary)
                            }
                            Text(relation.rationale)
                                .font(.footnote)
                                .foregroundStyle(VocabulleTheme.textSecondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            // La distinction entre lien attesté et rapprochement
                            // éditorial est exigée par le cahier des charges :
                            // l'utilisateur doit savoir ce qui est documenté.
                            Text(relation.evidence.displayName)
                                .font(.caption2)
                                .foregroundStyle(VocabulleTheme.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Ouvre la fiche de \(relation.targetTerm)")
                }
            }
        }
    }

    // MARK: - Sources

    @ViewBuilder
    private var sources: some View {
        SectionCard(title: "Sources et crédits") {
            if entry.sources.isEmpty {
                Text("Aucune source n'est associée à cette fiche.")
                    .font(.footnote)
                    .foregroundStyle(VocabulleTheme.caution)
            } else {
                ForEach(entry.sources) { source in
                    VStack(alignment: .leading, spacing: VocabulleTheme.Spacing.tight) {
                        HStack(spacing: VocabulleTheme.Spacing.small) {
                            Text(source.kind.displayName)
                                .font(VocabulleTheme.labelFont)
                                .foregroundStyle(VocabulleTheme.textSecondary)
                            if let revision = source.revisionID {
                                Text("révision \(revision)")
                                    .font(.caption2)
                                    .foregroundStyle(VocabulleTheme.textTertiary)
                            }
                        }
                        if let url = source.url {
                            Link(source.title, destination: url)
                                .font(.footnote)
                                .foregroundStyle(VocabulleTheme.accent)
                        } else {
                            Text(source.title)
                                .font(.footnote)
                                .foregroundStyle(VocabulleTheme.textPrimary)
                        }
                        if let fetchedAt = source.fetchedAt {
                            Text("Consulté le \(FrenchFormat.calendarDay(fetchedAt, timeZone: .gmt))")
                                .font(.caption2)
                                .foregroundStyle(VocabulleTheme.textTertiary)
                        }
                        if let license = source.license {
                            VStack(alignment: .leading, spacing: 2) {
                                if let url = license.url {
                                    Link(license.displayName, destination: url)
                                        .font(.caption2)
                                        .foregroundStyle(VocabulleTheme.accent)
                                } else {
                                    Text(license.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(VocabulleTheme.textTertiary)
                                }
                                if let notice = license.modificationNotice {
                                    Text(notice)
                                        .font(.caption2)
                                        .foregroundStyle(VocabulleTheme.textTertiary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Carte de section avec titre.
struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: VocabulleTheme.Spacing.small) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(VocabulleTheme.textTertiary)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(VocabulleTheme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: VocabulleTheme.Radius.card, style: .continuous)
                .fill(VocabulleTheme.surface)
        )
    }
}

/// Mention de provenance d'un bloc de texte.
struct ProvenanceLabel: View {
    let provenance: FieldProvenance

    var body: some View {
        Text(provenance.displayName)
            .font(.caption2)
            .foregroundStyle(VocabulleTheme.textTertiary)
    }
}
