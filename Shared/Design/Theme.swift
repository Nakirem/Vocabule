import SwiftUI
import UIKit

/// Palette et constantes visuelles de Vocabulle.
///
/// # Pourquoi des couleurs calculées plutôt qu'un catalogue
///
/// Les valeurs vivent ici, en un seul endroit, plutôt que dans un
/// `Assets.xcassets` : la palette est petite, elle doit rester lisible dans une
/// revue de code, et une valeur écrite ici est vérifiable par
/// `scripts/validate_project.py`. Le mode sombre est obtenu par le trait
/// système, sans bascule manuelle : l'application suit les réglages de
/// l'appareil, elle n'impose rien.
///
/// Les contrastes sont choisis pour dépasser le rapport 4,5:1 exigé par les
/// règles d'accessibilité, dans les deux apparences.
public enum VocabulleTheme {

    // MARK: - Couleurs

    /// Fond crème en clair, presque noir en sombre.
    public static let background = adaptive(light: 0xFAF7F2, dark: 0x14120F)
    /// Fond des cartes, légèrement détaché du fond général.
    public static let surface = adaptive(light: 0xFFFFFF, dark: 0x1F1C18)
    /// Texte principal : très sombre en clair, très clair en sombre.
    public static let textPrimary = adaptive(light: 0x1A1815, dark: 0xF3F0EA)
    /// Texte secondaire : définitions, métadonnées.
    public static let textSecondary = adaptive(light: 0x5A544C, dark: 0xABA49A)
    /// Texte tertiaire : crédits, mentions de source.
    public static let textTertiary = adaptive(light: 0x837C72, dark: 0x7E776D)
    /// Violet doux, couleur d'accent de l'application.
    public static let accent = adaptive(light: 0x6B5B95, dark: 0xB3A4E0)
    /// Avertissement de registre : vieilli, péjoratif, argotique.
    public static let caution = adaptive(light: 0x9C5227, dark: 0xE0A279)
    /// Séparateurs et bordures discrètes.
    public static let separator = adaptive(light: 0xE3DDD3, dark: 0x35302A)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    // MARK: - Espacements

    public enum Spacing {
        public static let tight: CGFloat = 4
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 16
        public static let large: CGFloat = 24
        public static let extraLarge: CGFloat = 32
    }

    // MARK: - Rayons

    public enum Radius {
        public static let card: CGFloat = 16
        public static let chip: CGFloat = 8
    }

    // MARK: - Typographie

    /// Police du terme affiché en grand.
    ///
    /// On utilise la police système et `Font.TextStyle` : les tailles suivent
    /// automatiquement Dynamic Type, y compris les très grandes tailles
    /// d'accessibilité. Une police embarquée devrait être redimensionnée à la
    /// main et casserait cet ajustement.
    public static func termFont(for style: Font.TextStyle) -> Font {
        .system(style, design: .serif, weight: .semibold)
    }

    public static let bodyFont = Font.system(.body, design: .default)
    public static let definitionFont = Font.system(.body, design: .serif)
    public static let labelFont = Font.system(.caption, design: .default, weight: .medium)
}

/// Étiquette de registre, signalée lorsqu'elle peut induire en erreur.
public struct RegisterChip: View {
    public let label: String
    public let isCaution: Bool

    public init(label: String, isCaution: Bool) {
        self.label = label
        self.isCaution = isCaution
    }

    public var body: some View {
        Text(label)
            .font(VocabulleTheme.labelFont)
            .foregroundStyle(isCaution ? VocabulleTheme.caution : VocabulleTheme.textSecondary)
            .padding(.horizontal, VocabulleTheme.Spacing.small)
            .padding(.vertical, VocabulleTheme.Spacing.tight)
            .background(
                RoundedRectangle(cornerRadius: VocabulleTheme.Radius.chip, style: .continuous)
                    .fill(VocabulleTheme.separator.opacity(0.55))
            )
            .accessibilityLabel(isCaution ? "Registre signalé : \(label)" : "Registre : \(label)")
    }
}

public extension UIColor {
    /// Construit une couleur depuis un entier `0xRRGGBB`.
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
