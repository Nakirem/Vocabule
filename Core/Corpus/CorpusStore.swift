import Foundation

/// Version allégée d'une fiche, destinée aux listes.
///
/// La Collection et les résultats de recherche affichent des centaines de
/// lignes : charger les fiches complètes pour n'en montrer que le titre
/// coûterait plusieurs mégaoctets de mémoire. Le résumé ne contient que ce qui
/// est affiché.
public struct EntrySummary: Codable, Hashable, Sendable, Identifiable {
    public let id: EntryID
    public let term: String
    public let kind: EntryKind
    public let category: EntryCategory
    public let shortDefinition: String
    /// Étiquette grammaticale compacte : « nom féminin », « locution verbale ».
    public let compactGrammar: String?
    public let registerLabel: String?
    /// `true` si un des registres de la fiche doit être signalé à l'utilisateur.
    ///
    /// Porté par le résumé et non calculé à l'affichage : le widget et l'écran
    /// Aujourd'hui n'ont que le résumé en main, et ne doivent surtout pas
    /// charger la fiche complète — ni pour afficher, ni pour avertir. Un terme
    /// vieilli ou péjoratif affiché sans avertissement sur l'écran verrouillé
    /// serait exactement ce que le cahier des charges interdit.
    public let registerWarning: Bool
    public let difficulty: Int

    public init(
        id: EntryID,
        term: String,
        kind: EntryKind,
        category: EntryCategory,
        shortDefinition: String,
        compactGrammar: String? = nil,
        registerLabel: String? = nil,
        registerWarning: Bool = false,
        difficulty: Int = 2
    ) {
        self.id = id
        self.term = term
        self.kind = kind
        self.category = category
        self.shortDefinition = shortDefinition
        self.compactGrammar = compactGrammar
        self.registerLabel = registerLabel
        self.registerWarning = registerWarning
        self.difficulty = difficulty
    }
}

/// Informations sur le corpus embarqué.
///
/// Affichées dans les réglages : l'utilisateur doit pouvoir savoir combien de
/// termes contient son corpus, de quand il date et sous quelle licence il est
/// publié — ces mentions sont obligatoires pour un contenu sous CC BY-SA.
public struct CorpusMetadata: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    /// Date de production du corpus, en UTC.
    public let generatedAt: Date
    public let entryCount: Int
    /// Nombre de fiches par catégorie, indexé par `EntryCategory.rawValue`.
    public let countsByCategory: [String: Int]
    /// Projet source principal, par exemple `fr.wiktionary.org`.
    public let sourceProject: String
    public let licenseName: String
    /// Version de la chaîne de production qui a fabriqué ce fichier.
    public let pipelineVersion: String

    public init(
        schemaVersion: Int,
        generatedAt: Date,
        entryCount: Int,
        countsByCategory: [String: Int],
        sourceProject: String,
        licenseName: String,
        pipelineVersion: String
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.entryCount = entryCount
        self.countsByCategory = countsByCategory
        self.sourceProject = sourceProject
        self.licenseName = licenseName
        self.pipelineVersion = pipelineVersion
    }

    public func count(for category: EntryCategory) -> Int {
        countsByCategory[category.rawValue] ?? 0
    }
}

/// Une lettre de l'alphabet et le rang de la première fiche qui commence par
/// elle, dans le parcours de la Collection.
///
/// Les deux moitiés sont nécessaires : la lettre à afficher, et le rang à
/// atteindre. Le rang est un **décalage de pagination**, pas un identifiant,
/// parce que c'est ce que `summaries(category:limit:offset:)` sait consommer —
/// la barre de lettres charge donc les pages qu'il faut avant de faire défiler
/// la liste jusqu'à ce rang.
public struct LetterAnchor: Sendable, Hashable, Identifiable {
    /// Lettre affichée, en capitale.
    public let letter: String
    /// Rang de la première fiche de la lettre, dans l'ordre du parcours.
    public let offset: Int
    /// Nombre de fiches qui commencent par cette lettre.
    public let count: Int

    public var id: String { letter }

    public init(letter: String, offset: Int, count: Int) {
        self.letter = letter
        self.offset = offset
        self.count = count
    }
}

/// Accès en lecture au corpus lexical.
///
/// Le protocole est volontairement étroit : l'extension widget ne doit jamais
/// charger le corpus entier, seulement les quelques fiches dont elle a besoin.
/// Un protocole large inviterait exactement l'erreur inverse.
public protocol CorpusStore: Sendable {
    /// Informations générales sur le corpus.
    func metadata() throws -> CorpusMetadata

    /// Fiche complète, pour l'écran Fiche.
    func entry(withID id: EntryID) throws -> LexicalEntry?

    /// Résumé d'une fiche, pour les listes et le widget.
    func summary(withID id: EntryID) throws -> EntrySummary?

    /// Résumés de plusieurs fiches, dans l'ordre demandé.
    ///
    /// Les identifiants inconnus sont ignorés : une fiche retirée du corpus
    /// après une mise à jour ne doit pas faire échouer l'affichage de la
    /// Collection, elle doit simplement disparaître.
    func summaries(withIDs ids: [EntryID]) throws -> [EntrySummary]

    /// Identifiants candidats d'une catégorie, **ordonnés de façon stable**.
    ///
    /// L'ordre est celui des identifiants, croissant. C'est ce qui rend le
    /// tirage reproductible : le moteur de sélection choisit un rang dans cette
    /// liste, et le même rang désigne toujours la même fiche.
    func candidateIDs(
        category: EntryCategory,
        excluding excluded: Set<EntryID>,
        limit: Int
    ) throws -> [EntryID]

    /// Nombre de fiches disponibles par catégorie, hors termes exclus.
    func candidateCount(category: EntryCategory, excluding excluded: Set<EntryID>) throws -> Int

    /// Recherche par terme ou définition.
    ///
    /// L'implémentation s'appuie sur une normalisation sans accents ni casse,
    /// pour que « ephemere » trouve « éphémère ».
    func search(_ query: String, limit: Int) throws -> [EntrySummary]

    /// Parcours paginé d'une catégorie, pour la Collection.
    func summaries(
        category: EntryCategory?,
        limit: Int,
        offset: Int
    ) throws -> [EntrySummary]

    /// Index alphabétique du parcours, dans l'ordre exact où `summaries` sert
    /// les fiches.
    ///
    /// Les décalages rendus désignent les mêmes fiches que la pagination de
    /// `summaries` : c'est le même filtre et le même tri. C'est la condition
    /// pour qu'une barre de lettres soit utile — un index calculé à côté
    /// enverrait l'utilisateur à côté de la lettre qu'il a touchée.
    func letterAnchors(category: EntryCategory?) throws -> [LetterAnchor]

    /// Nombre total de fiches.
    func entryCount() throws -> Int
}

public extension CorpusStore {
    /// Toutes les fiches d'une catégorie, sans exclusion.
    func candidateIDs(category: EntryCategory, limit: Int = Int.max) throws -> [EntryID] {
        try candidateIDs(category: category, excluding: [], limit: limit)
    }
}
