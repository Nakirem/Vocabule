import Foundation
import SQLite3

/// Passé à SQLite pour lui demander de recopier la chaîne immédiatement.
///
/// SQLite ne définit `SQLITE_TRANSIENT` que comme macro C, invisible depuis
/// Swift. La valeur sous-jacente est `(sqlite3_destructor_type)-1`.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Erreur d'accès au corpus embarqué.
public enum CorpusStoreError: Error, CustomStringConvertible {
    case databaseNotFound(String)
    case openFailed(String)
    case queryFailed(String, underlying: String)
    case unsupportedSchema(found: Int, supported: Int)
    case decodingFailed(String, underlying: String)

    public var description: String {
        switch self {
        case .databaseNotFound(let path):
            return "Corpus introuvable : \(path). L'application ne peut pas fonctionner sans son corpus."
        case .openFailed(let message):
            return "Ouverture du corpus impossible : \(message)"
        case .queryFailed(let query, let underlying):
            return "Requête en échec (\(query)) : \(underlying)"
        case .unsupportedSchema(let found, let supported):
            return "Corpus produit par une version plus récente (schéma \(found), pris en charge : \(supported))."
        case .decodingFailed(let column, let underlying):
            return "Fiche illisible (colonne \(column)) : \(underlying)"
        }
    }
}

/// Liste de colonnes SQL dont l'ordre de déclaration est l'unique source de
/// vérité.
///
/// # Pourquoi cette indirection
///
/// La liste passée à `SELECT` et les indices lus dans la ligne de résultat
/// décrivent le même ordre. Écrites séparément, ces deux déclarations finissent
/// par diverger — et c'est exactement ce qui est arrivé : `decodeEntry` lisait
/// `short_definition` en croyant lire `registers`, et son dernier indice
/// désignait une colonne qui n'existe pas. Le décodage échouait alors pour
/// **toutes** les fiches, en annonçant du JSON invalide dans une colonne qui
/// contenait du JSON parfaitement valide.
///
/// En dérivant la clause SQL et les indices de `allCases`, un décalage devient
/// impossible : il n'existe plus qu'une liste, et elle est ordonnée.
private protocol ColumnList: CaseIterable, Hashable {
    var rawValue: String { get }
}

private extension ColumnList {
    /// Clause de sélection, dans l'ordre de déclaration.
    static var sqlList: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }

    /// Position de la colonne dans la ligne de résultat.
    ///
    /// Comptage explicite plutôt que `firstIndex(of:)` : celui-ci renvoie
    /// `Self.AllCases.Index`, un type associé qui n'est pas convertible en
    /// entier et que le compilateur refuse de voir comme une position.
    var index: Int32 {
        var position: Int32 = 0
        for candidate in Self.allCases {
            if candidate == self { return position }
            position += 1
        }
        preconditionFailure("Colonne « \(rawValue) » absente de sa propre liste")
    }
}

/// Corpus lexical adossé à une base SQLite embarquée.
///
/// # Pourquoi SQLite et pas un JSON
///
/// Le corpus doit être interrogeable **par l'extension widget**, qui a un budget
/// mémoire très serré et un délai d'exécution limité. Charger un fichier JSON de
/// plusieurs mégaoctets pour n'afficher qu'un mot serait le contraire de ce que
/// le projet demande. SQLite permet de ne lire que les quelques lignes utiles.
///
/// # Ordre stable des candidats
///
/// `candidateIDs` renvoie les identifiants **triés par identifiant croissant**.
/// Ce n'est pas un détail de présentation : le moteur de sélection choisit un
/// *rang* dans cette liste, et le tirage doit être reproductible des années plus
/// tard, dans un autre processus. Un ordre qui dépendrait de l'ordre d'insertion
/// ou du plan d'exécution de SQLite produirait un terme différent pour le même
/// créneau selon le processus — exactement le défaut que le projet interdit.
///
/// # Fils d'exécution
///
/// Une seule connexion, protégée par un verrou. SQLite est compilé en mode
/// sérialisé sur iOS, mais s'appuyer sur ce détail de compilation pour la
/// correction serait fragile : le verrou rend la garantie explicite et son coût
/// est négligeable devant celui des requêtes.
public final class SQLiteCorpusStore: CorpusStore, @unchecked Sendable {

    /// Version du schéma de base attendue par ce binaire.
    public static let supportedSchemaVersion = 1

    private let handle: OpaquePointer
    private let lock = NSLock()
    private let path: String

    /// Ouvre le corpus en lecture seule.
    ///
    /// - Parameter url: emplacement du fichier `.sqlite`.
    /// - Throws: `CorpusStoreError.databaseNotFound` si le fichier n'existe pas,
    ///   ce qui signale un corpus oublié à l'embarquement plutôt qu'une base
    ///   vide — deux situations qu'il ne faut pas confondre.
    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CorpusStoreError.databaseNotFound(url.path)
        }
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &pointer, flags, nil) == SQLITE_OK, let opened = pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "raison inconnue"
            if let pointer { sqlite3_close_v2(pointer) }
            throw CorpusStoreError.openFailed(message)
        }
        self.handle = opened
        self.path = url.path

        do {
            try verifySchema()
        } catch {
            sqlite3_close_v2(opened)
            throw error
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    // MARK: - Vérification du schéma

    private func verifySchema() throws {
        let value = try? metadataValue(forKey: "schemaVersion")
        guard let value, let version = Int(value) else { return }
        guard version <= Self.supportedSchemaVersion else {
            throw CorpusStoreError.unsupportedSchema(
                found: version,
                supported: Self.supportedSchemaVersion
            )
        }
    }

    // MARK: - CorpusStore

    public func metadata() throws -> CorpusMetadata {
        guard let json = try metadataValue(forKey: "corpus") else {
            throw CorpusStoreError.queryFailed(
                "metadata[corpus]",
                underlying: "clé absente : le corpus n'a pas été produit par la chaîne officielle"
            )
        }
        guard let data = json.data(using: .utf8) else {
            throw CorpusStoreError.decodingFailed("metadata[corpus]", underlying: "encodage UTF-8 invalide")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(CorpusMetadata.self, from: data)
        } catch {
            throw CorpusStoreError.decodingFailed("metadata[corpus]", underlying: String(describing: error))
        }
    }

    public func entry(withID id: EntryID) throws -> LexicalEntry? {
        let sql = "SELECT \(EntryColumn.sqlList) FROM entries WHERE id = ? LIMIT 1;"
        return try withStatement(sql) { statement in
            bind(statement, 1, id.rawValue)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeEntry(statement)
        }
    }

    public func summary(withID id: EntryID) throws -> EntrySummary? {
        let sql = """
        SELECT \(SummaryColumn.sqlList)
        FROM entries WHERE id = ? LIMIT 1;
        """
        return try withStatement(sql) { statement in
            bind(statement, 1, id.rawValue)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeSummary(statement)
        }
    }

    public func summaries(withIDs ids: [EntryID]) throws -> [EntrySummary] {
        guard !ids.isEmpty else { return [] }
        // Les identifiants inconnus sont ignorés, et l'ordre demandé est
        // conservé : une fiche retirée du corpus doit disparaître de la
        // Collection, pas faire échouer son affichage.
        var found: [EntryID: EntrySummary] = [:]
        for chunk in ids.chunked(maxSize: Self.maxBindVariables) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let sql = """
            SELECT \(SummaryColumn.sqlList)
            FROM entries WHERE id IN (\(placeholders));
            """
            try withStatement(sql) { statement in
                for (offset, identifier) in chunk.enumerated() {
                    bind(statement, Int32(offset + 1), identifier.rawValue)
                }
                while sqlite3_step(statement) == SQLITE_ROW {
                    let summary = try decodeSummary(statement)
                    found[summary.id] = summary
                }
            }
        }
        return ids.compactMap { found[$0] }
    }

    public func candidateIDs(
        category: EntryCategory,
        excluding excluded: Set<EntryID>,
        limit: Int
    ) throws -> [EntryID] {
        guard limit > 0 else { return [] }
        // Le filtrage se fait en Swift et non dans la clause `IN` : la liste
        // d'exclusions peut dépasser la limite de variables liées de SQLite, et
        // une seule catégorie ne contient que quelques centaines d'identifiants.
        // Charger ces identifiants n'est pas « charger le corpus » : ce sont des
        // chaînes courtes, pas des fiches.
        let sql = "SELECT id FROM entries WHERE category = ? ORDER BY id ASC;"
        var result: [EntryID] = []
        try withStatement(sql) { statement in
            bind(statement, 1, category.rawValue)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let raw = text(statement, 0) else { continue }
                let identifier = EntryID(raw)
                if excluded.contains(identifier) { continue }
                result.append(identifier)
                if result.count >= limit { break }
            }
        }
        return result
    }

    public func candidateCount(category: EntryCategory, excluding excluded: Set<EntryID>) throws -> Int {
        let sql = "SELECT id FROM entries WHERE category = ? ORDER BY id ASC;"
        var count = 0
        try withStatement(sql) { statement in
            bind(statement, 1, category.rawValue)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let raw = text(statement, 0) else { continue }
                if !excluded.contains(EntryID(raw)) { count += 1 }
            }
        }
        return count
    }

    public func search(_ query: String, limit: Int) throws -> [EntrySummary] {
        guard limit > 0 else { return [] }
        let terms = SearchNormalizer.terms(in: query)
        guard !terms.isEmpty else { return [] }

        // Chaque mot doit être présent, dans n'importe quel ordre. Le classement
        // place d'abord les termes qui contiennent la requête entière, puis les
        // termes courts : « éphémère » avant une locution qui le mentionne.
        let conditions = Array(repeating: "search_text LIKE ?", count: terms.count).joined(separator: " AND ")
        let normalizedQuery = SearchNormalizer.normalize(query)
        let sql = """
        SELECT \(SummaryColumn.sqlList)
        FROM entries
        WHERE \(conditions)
        ORDER BY CASE WHEN term_search LIKE ? THEN 0 ELSE 1 END, length(term) ASC, id ASC
        LIMIT ?;
        """
        var result: [EntrySummary] = []
        try withStatement(sql) { statement in
            var index: Int32 = 1
            for term in terms {
                bind(statement, index, "%\(term)%")
                index += 1
            }
            bind(statement, index, "%\(normalizedQuery)%")
            index += 1
            sqlite3_bind_int(statement, index, Int32(clamping: limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(try decodeSummary(statement))
            }
        }
        return result
    }

    /// Clé de tri du parcours alphabétique de la Collection.
    ///
    /// `term_search` est le terme replié — sans accents, en minuscules — que
    /// produit la même normalisation que la recherche. Trier là-dessus range
    /// « éphémère » dans les E ; trier sur `term` la placerait après le z, car
    /// `COLLATE NOCASE` ne replie que l'ASCII et « é » (U+00E9) vaut plus que
    /// « z ». C'était le défaut : la Collection affichait ses accents à la fin,
    /// sous des initiales qui n'existent dans aucun alphabet.
    ///
    /// Le `replace` replie la ligature « œ », que la normalisation conserve
    /// volontairement — elle ne décompose ni « œ » ni « æ », comme
    /// `.diacriticInsensitive` côté Swift. Sans lui, la seule fiche du corpus
    /// qui commence par « œ » se retrouverait seule après le z, sous une lettre
    /// que personne ne cherche là. Un dictionnaire français range « œ » avec
    /// « oe ».
    private static let browseSortKey = "replace(term_search, 'œ', 'oe')"

    public func summaries(category: EntryCategory?, limit: Int, offset: Int) throws -> [EntrySummary] {
        guard limit > 0, offset >= 0 else { return [] }
        var sql = """
        SELECT \(SummaryColumn.sqlList)
        FROM entries
        """
        if category != nil { sql += " WHERE category = ?" }
        sql += " ORDER BY \(Self.browseSortKey) ASC, id ASC LIMIT ? OFFSET ?;"

        var result: [EntrySummary] = []
        try withStatement(sql) { statement in
            var index: Int32 = 1
            if let category {
                bind(statement, index, category.rawValue)
                index += 1
            }
            sqlite3_bind_int(statement, index, Int32(clamping: limit))
            sqlite3_bind_int(statement, index + 1, Int32(clamping: offset))
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(try decodeSummary(statement))
            }
        }
        return result
    }

    public func letterAnchors(category: EntryCategory?) throws -> [LetterAnchor] {
        // Même filtre et même tri que `summaries`, à la lettre près : les
        // décalages rendus ici désignent donc les fiches que la pagination
        // sert réellement. Un index calculé autrement — en comptant les termes
        // inférieurs à une lettre, par exemple — finirait par désigner un rang
        // voisin, et l'index de la Collection enverrait l'utilisateur à côté de
        // la lettre qu'il a touchée.
        var sql = """
        SELECT substr(\(Self.browseSortKey), 1, 1) AS letter, COUNT(*) AS total
        FROM entries
        """
        if category != nil { sql += " WHERE category = ?" }
        sql += " GROUP BY letter ORDER BY letter ASC;"

        var anchors: [LetterAnchor] = []
        var offset = 0
        try withStatement(sql) { statement in
            if let category { bind(statement, 1, category.rawValue) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let letter = text(statement, 0), !letter.isEmpty else { continue }
                let count = Int(sqlite3_column_int64(statement, 1))
                anchors.append(
                    LetterAnchor(letter: letter.uppercased(), offset: offset, count: count)
                )
                // Sous un tri lexicographique, toutes les chaînes qui partagent
                // une initiale sont contiguës : additionner les compteurs suffit
                // donc à retrouver le premier rang de chaque lettre, sans jamais
                // relire la table.
                offset += count
            }
        }
        return anchors
    }

    public func entryCount() throws -> Int {
        try withStatement("SELECT COUNT(*) FROM entries;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    // MARK: - Colonnes

    /// Requête complète, pour lire une fiche entière.
    ///
    /// L'ordre de ces cas **est** l'ordre de la clause `SELECT`. Ne jamais
    /// réordonner sans vérifier les décodeurs : ils s'y réfèrent par nom, donc
    /// ils suivent tout seuls.
    private enum EntryColumn: String, CaseIterable, ColumnList {
        case id, term, kind, category, difficulty
        case grammarPart = "grammar_part"
        case grammarGender = "grammar_gender"
        case grammarNote = "grammar_note"
        case grammarIPA = "grammar_ipa"
        case registers
        case shortDefinition = "short_definition"
        case shortProvenance = "short_provenance"
        case longDefinition = "long_definition"
        case longProvenance = "long_provenance"
        case usageNote = "usage_note"
        case usageNoteProvenance = "usage_note_provenance"
        case etymology
        case etymologyProvenance = "etymology_provenance"
        case history
        case historyProvenance = "history_provenance"
        case examples, relations, sources, tags
    }

    /// Requête allégée, pour les lignes de liste.
    ///
    /// Volontairement plus courte que `EntryColumn` : l'extension widget a un
    /// budget mémoire serré et n'affiche jamais la définition longue ni les
    /// relations. Attention, l'ordre **diffère** de `EntryColumn` — c'est
    /// précisément ce que cette énumération rend lisible.
    private enum SummaryColumn: String, CaseIterable, ColumnList {
        case id, term, kind, category
        case shortDefinition = "short_definition"
        case difficulty
        case grammarPart = "grammar_part"
        case grammarGender = "grammar_gender"
        case grammarNote = "grammar_note"
        case registers
    }

    // MARK: - Décodage

    private func decodeSummary(_ statement: OpaquePointer) throws -> EntrySummary {
        typealias Column = SummaryColumn
        guard let rawID = text(statement, Column.id), let term = text(statement, Column.term) else {
            throw CorpusStoreError.decodingFailed(
                Column.id.rawValue,
                underlying: "identifiant ou terme NULL"
            )
        }
        let kind = EntryKind(rawValue: text(statement, Column.kind) ?? "") ?? .word
        let category = EntryCategory(rawValue: text(statement, Column.category) ?? "") ?? .literary
        let registers = try decodeJSON([Register].self, from: statement, column: Column.registers)
        let grammar = GrammarInfo(
            partOfSpeech: text(statement, Column.grammarPart).flatMap(PartOfSpeech.init(rawValue:)),
            gender: text(statement, Column.grammarGender).flatMap(GrammaticalGender.init(rawValue:)),
            numberOrNote: text(statement, Column.grammarNote)
        )
        return EntrySummary(
            id: EntryID(rawID),
            term: term,
            kind: kind,
            category: category,
            shortDefinition: text(statement, Column.shortDefinition) ?? "",
            compactGrammar: grammar.compactLabel,
            registerLabel: registers.isEmpty ? nil : registers.map(\.displayName).joined(separator: ", "),
            registerWarning: registers.contains(where: \.needsWarning),
            difficulty: integer(statement, Column.difficulty)
        )
    }

    private func decodeEntry(_ statement: OpaquePointer) throws -> LexicalEntry {
        typealias Column = EntryColumn
        guard let rawID = text(statement, Column.id), let term = text(statement, Column.term) else {
            throw CorpusStoreError.decodingFailed(
                Column.id.rawValue,
                underlying: "identifiant ou terme NULL"
            )
        }
        let grammar = GrammarInfo(
            partOfSpeech: text(statement, Column.grammarPart).flatMap(PartOfSpeech.init(rawValue:)),
            gender: text(statement, Column.grammarGender).flatMap(GrammaticalGender.init(rawValue:)),
            numberOrNote: text(statement, Column.grammarNote),
            ipa: text(statement, Column.grammarIPA)
        )
        return LexicalEntry(
            id: EntryID(rawID),
            term: term,
            kind: EntryKind(rawValue: text(statement, Column.kind) ?? "") ?? .word,
            category: EntryCategory(rawValue: text(statement, Column.category) ?? "") ?? .literary,
            grammar: grammar,
            registers: try decodeJSON([Register].self, from: statement, column: Column.registers),
            difficulty: integer(statement, Column.difficulty),
            shortDefinition: try decodeText(statement, value: .shortDefinition, provenance: .shortProvenance),
            longDefinition: try decodeText(statement, value: .longDefinition, provenance: .longProvenance),
            usageNote: try decodeOptionalText(statement, value: .usageNote, provenance: .usageNoteProvenance),
            etymology: try decodeOptionalText(statement, value: .etymology, provenance: .etymologyProvenance),
            history: try decodeOptionalText(statement, value: .history, provenance: .historyProvenance),
            examples: try decodeJSON([Example].self, from: statement, column: Column.examples),
            relations: try decodeJSON([LexicalRelation].self, from: statement, column: Column.relations),
            sources: try decodeJSON([SourceRef].self, from: statement, column: Column.sources),
            tags: try decodeJSON([String].self, from: statement, column: Column.tags)
        )
    }

    private func decodeText(
        _ statement: OpaquePointer,
        value valueColumn: EntryColumn,
        provenance provenanceColumn: EntryColumn
    ) throws -> EntryText {
        guard let value = text(statement, valueColumn) else {
            throw CorpusStoreError.decodingFailed(valueColumn.rawValue, underlying: "texte NULL")
        }
        let raw = text(statement, provenanceColumn) ?? FieldProvenance.editorial.rawValue
        return EntryText(value, provenance: FieldProvenance(rawValue: raw) ?? .editorial)
    }

    private func decodeOptionalText(
        _ statement: OpaquePointer,
        value valueColumn: EntryColumn,
        provenance provenanceColumn: EntryColumn
    ) throws -> EntryText? {
        guard let value = text(statement, valueColumn), !value.isEmpty else { return nil }
        let raw = text(statement, provenanceColumn) ?? FieldProvenance.editorial.rawValue
        return EntryText(value, provenance: FieldProvenance(rawValue: raw) ?? .editorial)
    }

    /// Lit une colonne JSON et la décode.
    ///
    /// Le nom servant au message d'erreur est dérivé du cas d'énumération,
    /// jamais réécrit à la main : un message qui désignerait une autre colonne
    /// que celle réellement lue enverrait la recherche au mauvais endroit —
    /// exactement ce qui s'est produit avec `registers`.
    private func decodeJSON<T: Decodable, C: ColumnList>(
        _ type: T.Type,
        from statement: OpaquePointer,
        column: C
    ) throws -> T {
        try decodeJSON(type, from: text(statement, column), column: column.rawValue)
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from raw: String?, column: String) throws -> T {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else {
            // Une liste absente vaut liste vide : une fiche sans exemple reste
            // affichable, seule une fiche sans définition ne l'est pas.
            guard let empty = "[]".data(using: .utf8),
                  let value = try? JSONDecoder().decode(T.self, from: empty)
            else {
                throw CorpusStoreError.decodingFailed(column, underlying: "valeur absente")
            }
            return value
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw CorpusStoreError.decodingFailed(column, underlying: String(describing: error))
        }
    }

    // MARK: - Bas niveau

    private func metadataValue(forKey key: String) throws -> String? {
        try withStatement("SELECT value FROM metadata WHERE key = ? LIMIT 1;") { statement in
            bind(statement, 1, key)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return text(statement, 0)
        }
    }

    /// Nombre maximal de variables liées dans une requête.
    ///
    /// La valeur historique de SQLite est 999 ; les versions récentes montent à
    /// 32766. On reste délibérément sous la plus basse pour que le code
    /// fonctionne quel que soit le SQLite embarqué par la version d'iOS.
    private static let maxBindVariables = 500

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw CorpusStoreError.queryFailed(sql, underlying: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(prepared) }
        return try body(prepared)
    }

    /// Lecture d'une colonne désignée par son nom.
    ///
    /// Seul point d'entrée des décodeurs : ils ne manipulent jamais d'indice
    /// numérique, donc ils ne peuvent pas se désynchroniser de la clause
    /// `SELECT`.
    private func text<C: ColumnList>(_ statement: OpaquePointer, _ column: C) -> String? {
        text(statement, column.index)
    }

    private func integer<C: ColumnList>(_ statement: OpaquePointer, _ column: C) -> Int {
        Int(sqlite3_column_int(statement, column.index))
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index)
        else { return nil }
        return String(cString: pointer)
    }
}

private extension Array {
    /// Découpe en tranches d'au plus `maxSize` éléments.
    func chunked(maxSize: Int) -> [[Element]] {
        guard maxSize > 0, count > maxSize else { return isEmpty ? [] : [self] }
        var result: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: maxSize, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[index..<end]))
            index = end
        }
        return result
    }
}
