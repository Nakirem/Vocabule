import Foundation

/// Nature d'une source citée par une fiche.
public enum SourceKind: String, Codable, CaseIterable, Sendable {
    /// Page du Wiktionnaire francophone.
    case wiktionary
    /// Article de Wikipédia.
    case wikipedia
    /// Ouvrage de référence (dictionnaire, essai, manuel).
    case book
    /// Ressource en ligne autre que les deux premiers (site, base de données).
    case web

    public var displayName: String {
        switch self {
        case .wiktionary: return "Wiktionnaire"
        case .wikipedia: return "Wikipédia"
        case .book: return "Ouvrage"
        case .web: return "Ressource en ligne"
        }
    }
}

/// Référence vérifiable vers la source d'un contenu.
///
/// Règle éditoriale du projet : **on n'invente jamais une source**. Une fiche
/// dont une section n'a pas de source voit cette section supprimée, jamais
/// complétée par une référence plausible mais fictive. Le champ `url` est donc
/// toujours une adresse réellement consultée par la chaîne de production, et
/// `revisionID` permet de retrouver l'état exact de la page au moment de
/// l'extraction.
public struct SourceRef: Codable, Hashable, Sendable, Identifiable {
    public let kind: SourceKind
    /// Titre de la page ou de l'ouvrage, tel qu'il apparaît à la source.
    public let title: String
    /// Adresse consultée. Jamais reconstruite de mémoire.
    public let url: URL?
    /// Identifiant de révision MediaWiki, lorsque la source en fournit un.
    ///
    /// Il rend la citation reproductible : la page peut avoir changé depuis,
    /// l'identifiant désigne la version effectivement lue.
    public let revisionID: Int?
    /// Date de consultation, en UTC.
    public let fetchedAt: Date?
    /// Licence du contenu repris, telle qu'elle doit être affichée.
    public let license: ContentLicense?

    public var id: String {
        if let revisionID {
            return "\(kind.rawValue):\(title)#\(revisionID)"
        }
        return "\(kind.rawValue):\(title)"
    }

    public init(
        kind: SourceKind,
        title: String,
        url: URL? = nil,
        revisionID: Int? = nil,
        fetchedAt: Date? = nil,
        license: ContentLicense? = nil
    ) {
        self.kind = kind
        self.title = title
        self.url = url
        self.revisionID = revisionID
        self.fetchedAt = fetchedAt
        self.license = license
    }
}

/// Licence applicable à un contenu repris.
///
/// Vocabulle n'applique pas la même licence au code et aux contenus : le code
/// du projet et les textes repris du Wiktionnaire n'ont pas le même régime, et
/// l'interface doit pouvoir l'expliquer sans ambiguïté.
public enum ContentLicense: String, Codable, CaseIterable, Sendable {
    case ccBySa40 = "CC BY-SA 4.0"
    case ccBySa30 = "CC BY-SA 3.0"
    case ccBySa25 = "CC BY-SA 2.5"
    case ccBySa = "CC BY-SA"
    case publicDomain = "domaine public"
    case vocabulle = "rédaction Vocabulle"

    public var displayName: String { rawValue }

    /// Adresse de la licence, lorsqu'elle est publiée.
    public var url: URL? {
        switch self {
        case .ccBySa40, .ccBySa:
            return URL(string: "https://creativecommons.org/licenses/by-sa/4.0/deed.fr")
        case .ccBySa30:
            return URL(string: "https://creativecommons.org/licenses/by-sa/3.0/deed.fr")
        case .ccBySa25:
            return URL(string: "https://creativecommons.org/licenses/by-sa/2.5/deed.fr")
        case .publicDomain, .vocabulle:
            return nil
        }
    }

    /// Mention à afficher lorsque le contenu a été modifié.
    ///
    /// La licence CC BY-SA impose d'indiquer les modifications apportées. La
    /// chaîne de production reformate et raccourcit systématiquement les
    /// définitions : la mention est donc toujours due pour le Wiktionnaire.
    public var modificationNotice: String? {
        switch self {
        case .ccBySa40, .ccBySa30, .ccBySa25, .ccBySa:
            return "Contenu adapté et abrégé pour Vocabulle."
        case .publicDomain, .vocabulle:
            return nil
        }
    }
}
