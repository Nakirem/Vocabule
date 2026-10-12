import Foundation

/// Nature éditoriale d'une découverte.
///
/// Sert uniquement à équilibrer la sélection : une expression et un mot rare ne
/// se remplacent pas l'un l'autre dans la progression de l'utilisateur.
public enum EntryKind: String, Codable, CaseIterable, Sendable {
    /// Mot simple (lemme).
    case word
    /// Terme propre à un domaine (rhétorique, philosophie, sciences…).
    case technicalTerm
    /// Locution ou expression figée (« faire florès », « victoire à la Pyrrhus »).
    case expression

    public var displayName: String {
        switch self {
        case .word: return "Mot"
        case .technicalTerm: return "Terme spécialisé"
        case .expression: return "Expression"
        }
    }
}

/// Catégorie principale d'une fiche.
///
/// Chaque fiche possède **une seule** catégorie principale (utilisée pour
/// équilibrer la sélection) et autant de tags secondaires que nécessaire. Les
/// catégories peuvent se chevaucher : c'est la principale qui arbitre la
/// répartition éditoriale visée (40 / 25 / 20 / 15).
public enum EntryCategory: String, Codable, CaseIterable, Sendable {
    /// Mots littéraires, soutenus ou rares mais réutilisables (40 %).
    case literary
    /// Expressions et locutions (25 %).
    case expression
    /// Vocabulaire nuancé utile à la conversation (20 %).
    case conversation
    /// Termes spécialisés accessibles (15 %).
    case specialized

    public var displayName: String {
        switch self {
        case .literary: return "Littéraire"
        case .expression: return "Expression"
        case .conversation: return "Conversation"
        case .specialized: return "Spécialisé"
        }
    }

    public var shortDescription: String {
        switch self {
        case .literary: return "Mots soutenus ou rares, réutilisables à l'écrit"
        case .expression: return "Locutions figées et leur origine"
        case .conversation: return "Nuances utiles à l'oral"
        case .specialized: return "Termes de spécialité expliqués simplement"
        }
    }

    /// Part visée dans la sélection, exprimée en pourcentage.
    public var targetShare: Int {
        switch self {
        case .literary: return 40
        case .expression: return 25
        case .conversation: return 20
        case .specialized: return 15
        }
    }
}

/// Type de rapprochement entre deux fiches.
public enum RelationType: String, Codable, CaseIterable, Sendable {
    case synonym
    case antonym
    /// Même étymologie, même racine ou même formation.
    case sameOrigin
    /// Même courant intellectuel ou même cadre théorique.
    case sameSchool
    /// Même période d'usage attestée.
    case sameEra
    /// Contraste intéressant, sans être un antonyme strict.
    case contrast
    /// Même contexte culturel ou même domaine.
    case sameContext

    public var displayName: String {
        switch self {
        case .synonym: return "Synonyme"
        case .antonym: return "Antonyme"
        case .sameOrigin: return "Même origine"
        case .sameSchool: return "Même courant"
        case .sameEra: return "Même époque"
        case .contrast: return "Contraste"
        case .sameContext: return "Même contexte"
        }
    }
}

/// Statut du lien qui justifie un rapprochement.
///
/// Cette distinction est demandée explicitement : un rapprochement éditorial
/// (« ces deux mots se répondent ») n'a pas la même valeur qu'un lien
/// étymologique ou historique attesté par une source.
public enum RelationEvidence: String, Codable, CaseIterable, Sendable {
    /// Attesté par une source (étymologie commune, citation, dictionnaire).
    case attested
    /// Rapprochement éditorial assumé par Vocabulle, sans prétention historique.
    case editorial

    public var displayName: String {
        switch self {
        case .attested: return "Lien attesté"
        case .editorial: return "Rapprochement éditorial"
        }
    }
}

/// Provenance d'un exemple.
///
/// Aucune fausse citation : un exemple écrit pour Vocabulle est identifié comme
/// tel et n'est jamais attribué à un auteur.
public enum ExampleOrigin: String, Codable, CaseIterable, Sendable {
    /// Exemple rédigé par Vocabulle.
    case vocabulle
    /// Exemple relevé dans le Wiktionnaire.
    case wiktionary
    /// Exemple relevé dans Wikipédia.
    case wikipedia

    public var attribution: String? {
        switch self {
        case .vocabulle: return "Exemple rédigé pour Vocabulle"
        case .wiktionary: return "Exemple issu du Wiktionnaire"
        case .wikipedia: return "Exemple issu de Wikipédia"
        }
    }
}

/// Provenance d'un champ textuel de la fiche.
///
/// L'application affiche cette provenance : l'utilisateur doit pouvoir
/// distinguer ce qui vient d'une source de ce qui a été rédigé pour Vocabulle.
public enum FieldProvenance: String, Codable, CaseIterable, Sendable {
    /// Repris du Wiktionnaire (contenu sous licence CC BY-SA).
    case wiktionary
    /// Rédigé ou reformulé par la rédaction Vocabulle.
    case editorial
    /// Repris de Wikipédia.
    case wikipedia

    public var displayName: String {
        switch self {
        case .wiktionary: return "Wiktionnaire"
        case .editorial: return "Rédaction Vocabulle"
        case .wikipedia: return "Wikipédia"
        }
    }
}

/// Registre de langue, repris des étiquettes du Wiktionnaire.
public enum Register: String, Codable, CaseIterable, Sendable {
    case courant
    case soutenu
    case litteraire
    case familier
    case argotique
    case populaire
    case vieilli
    case desuet
    case rare
    case technique
    case pejorative
    case meliorative
    case humoristique
    case ironique
    case figure
    case parExtension
    case regionalisme

    public var displayName: String {
        switch self {
        case .courant: return "Courant"
        case .soutenu: return "Soutenu"
        case .litteraire: return "Littéraire"
        case .familier: return "Familier"
        case .argotique: return "Argotique"
        case .populaire: return "Populaire"
        case .vieilli: return "Vieilli"
        case .desuet: return "Désuet"
        case .rare: return "Rare"
        case .technique: return "Technique"
        case .pejorative: return "Péjoratif"
        case .meliorative: return "Mélioratif"
        case .humoristique: return "Humoristique"
        case .ironique: return "Ironique"
        case .figure: return "Figuré"
        case .parExtension: return "Par extension"
        case .regionalisme: return "Régionalisme"
        }
    }

    /// Indique si le registre mérite un avertissement visible dans l'interface.
    ///
    /// On ne transforme jamais un usage familier en diagnostic médical : les
    /// étiquettes qui peuvent heurter ou induire en erreur sont signalées.
    public var needsWarning: Bool {
        switch self {
        case .vieilli, .desuet, .pejorative, .argotique, .populaire, .rare:
            return true
        default:
            return false
        }
    }
}
