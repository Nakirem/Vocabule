import Foundation

/// Identifiant stable d'une fiche.
///
/// C'est un slug ASCII construit une fois pour toutes par la chaîne de
/// production (« monomaniaque », « victoire-a-la-pyrrhus »). Il est stable
/// entre l'application, l'extension widget et les lancements : il sert de clé
/// de lien profond (`vocabulle://terme/monomaniaque`) et de clé de l'historique
/// utilisateur. Il ne dépend jamais d'un hachage calculé à l'exécution, dont la
/// valeur pourrait changer d'une version de compilateur à l'autre.
public struct EntryID: Hashable, Codable, RawRepresentable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Construit un identifiant à partir d'un terme affiché.
    ///
    /// Utilisé par la chaîne de production et par les tests. Les accents et
    /// ligatures sont translittérés pour que l'identifiant reste utilisable dans
    /// une URL et dans un nom de fichier.
    public init(slugging term: String) {
        self.rawValue = Self.slug(from: term)
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: EntryID, rhs: EntryID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Translittération minimale et déterministe, sans dépendance à la locale.
    public static func slug(from term: String) -> String {
        let folded = term.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        var out = ""
        var lastWasDash = false
        for scalar in folded.unicodeScalars {
            let isAllowed = scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
            if isAllowed {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}

/// Nature grammaticale, telle qu'elle est affichée sur la fiche.
public enum PartOfSpeech: String, Codable, CaseIterable, Sendable {
    case nomCommun
    case nomPropre
    case adjectif
    case verbe
    case adverbe
    case locutionNominale
    case locutionVerbale
    case locutionAdjectivale
    case locutionAdverbiale
    case locutionInterjective
    case interjection
    case preposition
    case conjonction
    case pronom
    case determinant

    public var displayName: String {
        switch self {
        case .nomCommun: return "nom commun"
        case .nomPropre: return "nom propre"
        case .adjectif: return "adjectif"
        case .verbe: return "verbe"
        case .adverbe: return "adverbe"
        case .locutionNominale: return "locution nominale"
        case .locutionVerbale: return "locution verbale"
        case .locutionAdjectivale: return "locution adjectivale"
        case .locutionAdverbiale: return "locution adverbiale"
        case .locutionInterjective: return "locution interjective"
        case .interjection: return "interjection"
        case .preposition: return "préposition"
        case .conjonction: return "conjonction"
        case .pronom: return "pronom"
        case .determinant: return "déterminant"
        }
    }
}

/// Genre grammatical. Optionnel : une locution ou un adverbe n'en a pas.
public enum GrammaticalGender: String, Codable, CaseIterable, Sendable {
    case masculin
    case feminin
    case masculinOuFeminin
    case invariable

    public var displayName: String {
        switch self {
        case .masculin: return "masculin"
        case .feminin: return "féminin"
        case .masculinOuFeminin: return "masculin ou féminin"
        case .invariable: return "invariable"
        }
    }

    /// Abréviation compacte destinée au widget.
    public var abbreviation: String {
        switch self {
        case .masculin: return "m."
        case .feminin: return "f."
        case .masculinOuFeminin: return "m. ou f."
        case .invariable: return "inv."
        }
    }
}

/// Informations grammaticales affichées sous le terme.
public struct GrammarInfo: Codable, Hashable, Sendable {
    public var partOfSpeech: PartOfSpeech?
    public var gender: GrammaticalGender?
    /// Mention libre : « pluriel rare », « s'emploie surtout au figuré ».
    public var numberOrNote: String?
    /// Prononciation API, sans les crochets.
    public var ipa: String?

    public init(
        partOfSpeech: PartOfSpeech? = nil,
        gender: GrammaticalGender? = nil,
        numberOrNote: String? = nil,
        ipa: String? = nil
    ) {
        self.partOfSpeech = partOfSpeech
        self.gender = gender
        self.numberOrNote = numberOrNote
        self.ipa = ipa
    }

    /// Ligne compacte du type « nom féminin », ou `nil` si rien n'est connu.
    public var compactLabel: String? {
        var pieces: [String] = []
        if let partOfSpeech {
            if let gender, partOfSpeech == .nomCommun || partOfSpeech == .adjectif {
                pieces.append("\(partOfSpeech.displayName) \(gender.displayName)")
            } else {
                pieces.append(partOfSpeech.displayName)
            }
        } else if let gender {
            pieces.append(gender.displayName)
        }
        if let numberOrNote, !numberOrNote.isEmpty {
            pieces.append(numberOrNote)
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: ", ")
    }
}

/// Texte de fiche accompagné de sa provenance.
///
/// Chaque bloc affiché à l'utilisateur sait d'où il vient. C'est une exigence
/// explicite du projet : les textes repris du Wiktionnaire (CC BY-SA) et les
/// textes rédigés par Vocabulle n'ont ni le même statut ni les mêmes obligations
/// d'attribution.
public struct EntryText: Codable, Hashable, Sendable {
    public let value: String
    public let provenance: FieldProvenance

    public init(_ value: String, provenance: FieldProvenance) {
        self.value = value
        self.provenance = provenance
    }

    public var isEmpty: Bool { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Exemple d'emploi.
public struct Example: Codable, Hashable, Sendable {
    public let text: String
    public let origin: ExampleOrigin
    /// Auteur ou ouvrage, uniquement lorsque la source le nomme explicitement.
    ///
    /// Vocabulle n'attribue **jamais** un exemple à un auteur de mémoire : si la
    /// source ne nomme personne, ce champ reste vide et l'exemple est présenté
    /// comme relevant du Wiktionnaire.
    public let attributedTo: String?
    /// Titre de la source d'où l'exemple est tiré, si elle est connue.
    public let sourceTitle: String?

    public init(
        text: String,
        origin: ExampleOrigin,
        attributedTo: String? = nil,
        sourceTitle: String? = nil
    ) {
        self.text = text
        self.origin = origin
        self.attributedTo = attributedTo
        self.sourceTitle = sourceTitle
    }

    /// Mention affichée sous l'exemple.
    public var creditLine: String {
        if let attributedTo, !attributedTo.isEmpty {
            return "\(origin.attribution ?? "") — \(attributedTo)"
        }
        return origin.attribution ?? ""
    }

    /// `true` si l'exemple prétend venir d'une source sans nommer d'auteur.
    ///
    /// Sert au rapport de validation : un exemple attribué sans nom d'auteur
    /// exploitable est un défaut de la chaîne de production, pas un détail.
    public var hasUnverifiableAttribution: Bool {
        guard origin != .vocabulle else { return false }
        return attributedTo?.isEmpty ?? true
    }
}

/// Terme associé, avec la raison explicite du rapprochement.
///
/// Le projet interdit les listes de mots « qui vont bien ensemble » : chaque
/// association porte une phrase qui dit *pourquoi* ces deux termes se
/// répondent, et un statut qui distingue un lien attesté d'un rapprochement
/// éditorial.
public struct LexicalRelation: Codable, Hashable, Sendable {
    public let targetID: EntryID
    /// Terme affichable, dupliqué pour éviter une jointure côté widget.
    public let targetTerm: String
    public let type: RelationType
    public let evidence: RelationEvidence
    /// Phrase justifiant le rapprochement. Obligatoire et non vide.
    public let rationale: String

    public init(
        targetID: EntryID,
        targetTerm: String,
        type: RelationType,
        evidence: RelationEvidence,
        rationale: String
    ) {
        self.targetID = targetID
        self.targetTerm = targetTerm
        self.type = type
        self.evidence = evidence
        self.rationale = rationale
    }
}

/// Fiche lexicale complète.
public struct LexicalEntry: Codable, Hashable, Sendable, Identifiable {
    /// Longueur maximale de la définition courte affichée par le widget.
    ///
    /// Le WidgetKit tronque sans prévenir : on préfère contraindre la chaîne de
    /// production et refuser une fiche trop bavarde plutôt que d'afficher une
    /// phrase coupée en plein milieu sur l'écran verrouillé.
    public static let shortDefinitionMaxLength = 120

    public let id: EntryID
    /// Terme tel qu'il doit être affiché, avec ses accents.
    public let term: String
    public let kind: EntryKind
    public let category: EntryCategory
    public let grammar: GrammarInfo
    public let registers: [Register]
    /// Difficulté indicative de 1 (accessible) à 3 (exigeant).
    public let difficulty: Int

    /// Définition courte : une phrase, pour l'écran verrouillé.
    public let shortDefinition: EntryText
    /// Définition longue, en une à trois phrases claires.
    public let longDefinition: EntryText
    /// « Quand l'utiliser ? » — conseil d'emploi, jamais une prescription.
    public let usageNote: EntryText?
    /// Étymologie.
    public let etymology: EntryText?
    /// Histoire ou anecdote documentée.
    public let history: EntryText?

    public let examples: [Example]
    public let relations: [LexicalRelation]
    public let sources: [SourceRef]
    public let tags: [String]

    public init(
        id: EntryID,
        term: String,
        kind: EntryKind,
        category: EntryCategory,
        grammar: GrammarInfo = GrammarInfo(),
        registers: [Register] = [],
        difficulty: Int = 2,
        shortDefinition: EntryText,
        longDefinition: EntryText,
        usageNote: EntryText? = nil,
        etymology: EntryText? = nil,
        history: EntryText? = nil,
        examples: [Example] = [],
        relations: [LexicalRelation] = [],
        sources: [SourceRef] = [],
        tags: [String] = []
    ) {
        self.id = id
        self.term = term
        self.kind = kind
        self.category = category
        self.grammar = grammar
        self.registers = registers
        self.difficulty = difficulty
        self.shortDefinition = shortDefinition
        self.longDefinition = longDefinition
        self.usageNote = usageNote
        self.etymology = etymology
        self.history = history
        self.examples = examples
        self.relations = relations
        self.sources = sources
        self.tags = tags
    }
}

public extension LexicalEntry {
    /// Registres qui doivent être signalés visuellement.
    var warnedRegisters: [Register] {
        registers.filter(\.needsWarning)
    }

    /// Ligne de registre affichée à côté du terme, par exemple « soutenu, rare ».
    var registerLabel: String? {
        registers.isEmpty ? nil : registers.map(\.displayName).joined(separator: ", ")
    }

    /// Sources effectivement responsables du contenu repris.
    ///
    /// Une fiche sans source n'est pas affichable : la chaîne de production
    /// écarte ces candidates plutôt que de les publier sans référence.
    var attributionSources: [SourceRef] {
        sources.filter { $0.kind == .wiktionary || $0.kind == .wikipedia }
    }

    /// Licences distinctes à mentionner pour cette fiche.
    var licenses: [ContentLicense] {
        var seen = Set<ContentLicense>()
        var result: [ContentLicense] = []
        for source in sources {
            guard let license = source.license, !seen.contains(license) else { continue }
            seen.insert(license)
            result.append(license)
        }
        return result
    }

    /// Vérifie les invariants éditoriaux minimaux.
    ///
    /// Utilisé par les tests et par le rapport de validation de la chaîne de
    /// production. Une fiche qui échoue ici ne doit pas être publiée.
    func validate() -> [EntryValidationIssue] {
        var issues: [EntryValidationIssue] = []

        if term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyTerm)
        }
        if id.rawValue.isEmpty {
            issues.append(.emptyIdentifier)
        }
        if shortDefinition.isEmpty {
            issues.append(.missingShortDefinition)
        }
        if shortDefinition.value.count > Self.shortDefinitionMaxLength {
            issues.append(.shortDefinitionTooLong(shortDefinition.value.count))
        }
        if longDefinition.isEmpty {
            issues.append(.missingLongDefinition)
        }
        if examples.count > 2 {
            issues.append(.tooManyExamples(examples.count))
        }
        if relations.count < 2 || relations.count > 4 {
            issues.append(.relationCountOutOfRange(relations.count))
        }
        if relations.contains(where: { $0.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            issues.append(.relationWithoutRationale)
        }
        if relations.contains(where: { $0.targetID == id }) {
            issues.append(.selfReferentialRelation)
        }
        if attributionSources.isEmpty {
            issues.append(.missingAttributionSource)
        }
        if examples.contains(where: \.hasUnverifiableAttribution) {
            issues.append(.exampleWithUnverifiableAttribution)
        }
        // Un contenu marqué comme repris du Wiktionnaire doit citer au moins une
        // page du Wiktionnaire : sans cela, l'attribution affichée serait fausse.
        let textualFields = [shortDefinition, longDefinition, usageNote, etymology, history].compactMap { $0 }
        let claimsWiktionary = textualFields.contains { $0.provenance == .wiktionary }
        if claimsWiktionary, !sources.contains(where: { $0.kind == .wiktionary }) {
            issues.append(.wiktionaryProvenanceWithoutSource)
        }
        if !(1...3).contains(difficulty) {
            issues.append(.difficultyOutOfRange(difficulty))
        }
        return issues
    }
}

/// Défaut bloquant détecté sur une fiche.
public enum EntryValidationIssue: Hashable, Sendable, CustomStringConvertible {
    case emptyTerm
    case emptyIdentifier
    case missingShortDefinition
    case shortDefinitionTooLong(Int)
    case missingLongDefinition
    case tooManyExamples(Int)
    case relationCountOutOfRange(Int)
    case relationWithoutRationale
    case selfReferentialRelation
    case missingAttributionSource
    case exampleWithUnverifiableAttribution
    case wiktionaryProvenanceWithoutSource
    case difficultyOutOfRange(Int)

    public var description: String {
        switch self {
        case .emptyTerm: return "terme vide"
        case .emptyIdentifier: return "identifiant vide"
        case .missingShortDefinition: return "définition courte absente"
        case .shortDefinitionTooLong(let count): return "définition courte trop longue (\(count) caractères)"
        case .missingLongDefinition: return "définition longue absente"
        case .tooManyExamples(let count): return "trop d'exemples (\(count))"
        case .relationCountOutOfRange(let count): return "nombre de termes associés hors plage (\(count))"
        case .relationWithoutRationale: return "terme associé sans justification"
        case .selfReferentialRelation: return "fiche liée à elle-même"
        case .missingAttributionSource: return "aucune source d'attribution"
        case .exampleWithUnverifiableAttribution: return "exemple attribué sans auteur vérifiable"
        case .wiktionaryProvenanceWithoutSource: return "provenance Wiktionnaire sans source Wiktionnaire"
        case .difficultyOutOfRange(let value): return "difficulté hors plage (\(value))"
        }
    }
}
