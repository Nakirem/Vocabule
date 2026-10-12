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
        let sql = "SELECT \(Self.entryColumns) FROM entries WHERE id = ? LIMIT 1;"
        return try withStatement(sql) { statement in
            bind(statement, 1, id.rawValue)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeEntry(statement)
        }
    }

    public func summary(withID id: EntryID) throws -> EntrySummary? {
        let sql = """
        SELECT id, term, kind, category, short_definition, difficulty,
               grammar_part, grammar_gender, grammar_note, registers
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
            SELECT id, term, kind, category, short_definition, difficulty,
                   grammar_part, grammar_gender, grammar_note, registers
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
        SELECT id, term, kind, category, short_definition, difficulty,
               grammar_part, grammar_gender, grammar_note, registers
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

    public func summaries(category: EntryCategory?, limit: Int, offset: Int) throws -> [EntrySummary] {
        guard limit > 0, offset >= 0 else { return [] }
        var sql = """
        SELECT id, term, kind, category, short_definition, difficulty,
               grammar_part, grammar_gender, grammar_note, registers
        FROM entries
        """
        if category != nil { sql += " WHERE category = ?" }
        sql += " ORDER BY term COLLATE NOCASE ASC, id ASC LIMIT ? OFFSET ?;"

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

    public func entryCount() throws -> Int {
        try withStatement("SELECT COUNT(*) FROM entries;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    // MARK: - Colonnes

    private static let entryColumns = """
    id, term, kind, category, difficulty, grammar_part, grammar_gender, grammar_note, grammar_ipa,
    registers, short_definition, short_provenance, long_definition, long_provenance,
    usage_note, usage_note_provenance, etymology, etymology_provenance, history, history_provenance,
    examples, relations, sources, tags
    """

    // MARK: - Décodage

    private func decodeSummary(_ statement: OpaquePointer) throws -> EntrySummary {
        guard let rawID = text(statement, 0), let term = text(statement, 1) else {
            throw CorpusStoreError.decodingFailed("id", underlying: "identifiant ou terme NULL")
        }
        let kind = EntryKind(rawValue: text(statement, 2) ?? "") ?? .word
        let category = EntryCategory(rawValue: text(statement, 3) ?? "") ?? .literary
        let registers = try decodeJSON([Register].self, from: text(statement, 9), column: "registers")
        let grammar = GrammarInfo(
            partOfSpeech: text(statement, 6).flatMap(PartOfSpeech.init(rawValue:)),
            gender: text(statement, 7).flatMap(GrammaticalGender.init(rawValue:)),
            numberOrNote: text(statement, 8)
        )
        return EntrySummary(
            id: EntryID(rawID),
            term: term,
            kind: kind,
            category: category,
            shortDefinition: text(statement, 4) ?? "",
            compactGrammar: grammar.compactLabel,
            registerLabel: registers.isEmpty ? nil : registers.map(\.displayName).joined(separator: ", "),
            registerWarning: registers.contains(where: \.needsWarning),
            difficulty: Int(sqlite3_column_int(statement, 5))
        )
    }

    private func decodeEntry(_ statement: OpaquePointer) throws -> LexicalEntry {
        guard let rawID = text(statement, 0), let term = text(statement, 1) else {
            throw CorpusStoreError.decodingFailed("id", underlying: "identifiant ou terme NULL")
        }
        let grammar = GrammarInfo(
            partOfSpeech: text(statement, 5).flatMap(PartOfSpeech.init(rawValue:)),
            gender: text(statement, 6).flatMap(GrammaticalGender.init(rawValue:)),
            numberOrNote: text(statement, 7),
            ipa: text(statement, 8)
        )
        return LexicalEntry(
            id: EntryID(rawID),
            term: term,
            kind: EntryKind(rawValue: text(statement, 2) ?? "") ?? .word,
            category: EntryCategory(rawValue: text(statement, 3) ?? "") ?? .literary,
            grammar: grammar,
            registers: try decodeJSON([Register].self, from: text(statement, 10), column: "registers"),
            difficulty: Int(sqlite3_column_int(statement, 4)),
            shortDefinition: try decodeText(statement, value: 11, provenance: 12, column: "short_definition"),
            longDefinition: try decodeText(statement, value: 13, provenance: 14, column: "long_definition"),
            usageNote: try decodeOptionalText(statement, value: 15, provenance: 16, column: "usage_note"),
            etymology: try decodeOptionalText(statement, value: 17, provenance: 18, column: "etymology"),
            history: try decodeOptionalText(statement, value: 19, provenance: 20, column: "history"),
            examples: try decodeJSON([Example].self, from: text(statement, 21), column: "examples"),
            relations: try decodeJSON([LexicalRelation].self, from: text(statement, 22), column: "relations"),
            sources: try decodeJSON([SourceRef].self, from: text(statement, 23), column: "sources"),
            tags: try decodeJSON([String].self, from: text(statement, 24), column: "tags")
        )
    }

    private func decodeText(
        _ statement: OpaquePointer,
        value: Int32,
        provenance: Int32,
        column: String
    ) throws -> EntryText {
        guard let value = text(statement, value) else {
            throw CorpusStoreError.decodingFailed(column, underlying: "texte NULL")
        }
        let raw = text(statement, provenance) ?? FieldProvenance.editorial.rawValue
        return EntryText(value, provenance: FieldProvenance(rawValue: raw) ?? .editorial)
    }

    private func decodeOptionalText(
        _ statement: OpaquePointer,
        value: Int32,
        provenance: Int32,
        column: String
    ) throws -> EntryText? {
        guard let value = text(statement, value), !value.isEmpty else { return nil }
        let raw = text(statement, provenance) ?? FieldProvenance.editorial.rawValue
        return EntryText(value, provenance: FieldProvenance(rawValue: raw) ?? .editorial)
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
