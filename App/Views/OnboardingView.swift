import SwiftUI

/// Écran de premier lancement.
///
/// Son seul rôle est d'expliquer ce que l'application fait et ce qu'elle ne fait
/// pas, puis de disparaître. Aucune demande d'autorisation n'y figure : afficher
/// une demande de notifications avant que l'utilisateur ait vu une seule
/// découverte serait une pression, et l'application fonctionne sans.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VocabulleTheme.Spacing.large) {
                header
                ForEach(Array(Self.points.enumerated()), id: \.offset) { _, point in
                    card(point)
                }
                disclosure
                startButton
            }
            .padding(VocabulleTheme.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(VocabulleTheme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: VocabulleTheme.Spacing.small) {
            Text("Vocabulle")
                .font(VocabulleTheme.termFont(for: .largeTitle))
                .foregroundStyle(VocabulleTheme.textPrimary)
            Text("Trois mots par jour, choisis pour être réutilisés — pas pour remplir une liste.")
                .font(VocabulleTheme.definitionFont)
                .foregroundStyle(VocabulleTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card(_ point: Point) -> some View {
        HStack(alignment: .top, spacing: VocabulleTheme.Spacing.medium) {
            Image(systemName: point.symbol)
                .font(.title3)
                .foregroundStyle(VocabulleTheme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: VocabulleTheme.Spacing.tight) {
                Text(point.title)
                    .font(VocabulleTheme.termFont(for: .headline))
                    .foregroundStyle(VocabulleTheme.textPrimary)
                Text(point.detail)
                    .font(.footnote)
                    .foregroundStyle(VocabulleTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(VocabulleTheme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: VocabulleTheme.Radius.card, style: .continuous)
                .fill(VocabulleTheme.surface)
        )
        .accessibilityElement(children: .combine)
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: VocabulleTheme.Spacing.small) {
            Text("Ce que Vocabulle ne fait pas")
                .font(VocabulleTheme.termFont(for: .headline))
                .foregroundStyle(VocabulleTheme.textPrimary)
            Text("Aucun compte, aucune publicité, aucune analyse d'usage, aucun serveur. Aucune connexion n'est nécessaire, y compris au premier lancement. Les textes repris du Wiktionnaire sont sous licence CC BY-SA et crédités sur chaque fiche ; les exemples écrits pour Vocabulle sont signalés comme tels.")
                .font(.footnote)
                .foregroundStyle(VocabulleTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(VocabulleTheme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: VocabulleTheme.Radius.card, style: .continuous)
                .fill(VocabulleTheme.separator.opacity(0.35))
        )
    }

    private var startButton: some View {
        Button {
            environment.completeOnboarding()
        } label: {
            Text("Voir ma première découverte")
                .frame(maxWidth: .infinity)
                .padding(.vertical, VocabulleTheme.Spacing.small)
        }
        .buttonStyle(.borderedProminent)
        .tint(VocabulleTheme.accent)
    }

    private struct Point {
        let symbol: String
        let title: String
        let detail: String
    }

    private static let points: [Point] = [
        Point(
            symbol: "sparkles",
            title: "Trois découvertes par jour",
            detail: "Le matin, l'après-midi et le soir. Le mot du soir reste affiché après minuit, jusqu'au lendemain matin. Vous choisissez les heures."
        ),
        Point(
            symbol: "lock.rectangle.stack",
            title: "Sur l'écran verrouillé",
            detail: "Le widget affiche le terme et sa définition courte, sans ouvrir l'application. Touchez-le pour lire la fiche complète."
        ),
        Point(
            symbol: "text.book.closed",
            title: "Une fiche utile, pas un dictionnaire",
            detail: "Nature, registre, définition longue, exemples, étymologie quand elle est documentée, et deux à quatre termes associés avec la raison du rapprochement."
        ),
        Point(
            symbol: "arrow.triangle.2.circlepath",
            title: "« Autre mot » et « Déjà connu »",
            detail: "« Autre mot » remplace la découverte sans la marquer comme sue. « Déjà connu » l'écarte des découvertes suivantes, jusqu'à ce que vous la décochiez."
        )
    ]
}
