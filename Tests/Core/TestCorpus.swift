import Foundation
@testable import VocabulleCore

/// Corpus en mémoire, utilisé par les tests de sélection.
///
/// Il se comporte comme l'implémentation SQLite sur les points qui comptent
/// pour la reproductibilité : `candidateIDs` renvoie toujours les identifiants
/// **triés par ordre croissant**. C'est cette garantie, et non le hasard, qui
/// fait qu'un même rang désigne toujours la même fiche — dans l'application
/// comme dans l'extension widget.
struct TestCorpus: CorpusStore {
    let entries: [LexicalEntry]
    private let byID: [EntryID: LexicalEntry]
    private let idsByCategory: [EntryCategory: [EntryID]]
    private let generatedAt: Date

    init(entries: [LexicalEntry], generatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.entries = entries
        self.generatedAt = generatedAt

        var index: [EntryID: LexicalEntry] = [:]
        var grouped: [EntryCategory: [EntryID]] = [:]
        for entry in entries {
            index[entry.id] = entry
            grouped[entry.category, default: []].append(entry.id)
        }
        self.byID = index
        self.idsByCategory = grouped.mapValues { $0.sorted() }
    }

    func metadata() throws -> CorpusMetadata {
        var counts: [String: Int] = [:]
        for (category, ids) in idsByCategory {
            counts[category.rawValue] = ids.count
        }
        return CorpusMetadata(
            schemaVersion: 1,
            generatedAt: generatedAt,
            entryCount: entries.count,
            countsByCategory: counts,
            sourceProject: "fr.wiktionary.org",
            licenseName: ContentLicense.ccBySa40.displayName,
            pipelineVersion: "test"
        )
    }

    func entry(withID id: EntryID) throws -> LexicalEntry? {
        byID[id]
    }

    func summary(withID id: EntryID) throws -> EntrySummary? {
        byID[id].map(Self.summary(for:))
    }

    func summaries(withIDs ids: [EntryID]) throws -> [EntrySummary] {
        ids.compactMap { byID[$0] }.map(Self.summary(for:))
    }

    func candidateIDs(
        category: EntryCategory,
        excluding excluded: Set<EntryID>,
        limit: Int
    ) throws -> [EntryID] {
        let available = (idsByCategory[category] ?? []).filter { !excluded.contains($0) }
        return Array(available.prefix(max(0, limit)))
    }

    func candidateCount(category: EntryCategory, excluding excluded: Set<EntryID>) throws -> Int {
        (idsByCategory[category] ?? []).reduce(0) { total, id in
            total + (excluded.contains(id) ? 0 : 1)
        }
    }

    func search(_ query: String, limit: Int) throws -> [EntrySummary] {
        let needle = Self.normalized(query)
        guard !needle.isEmpty else { return [] }
        return entries
            .filter {
                Self.normalized($0.term).contains(needle)
                    || Self.normalized($0.shortDefinition.value).contains(needle)
            }
            .sorted { $0.id < $1.id }
            .prefix(max(0, limit))
            .map(Self.summary(for:))
    }

    func summaries(category: EntryCategory?, limit: Int, offset: Int) throws -> [EntrySummary] {
        let ids: [EntryID]
        if let category {
            ids = idsByCategory[category] ?? []
        } else {
            ids = entries.map(\.id).sorted()
        }
        guard offset >= 0, offset < ids.count else { return [] }
        return ids
            .dropFirst(offset)
            .prefix(max(0, limit))
            .compactMap { byID[$0] }
            .map(Self.summary(for:))
    }

    func entryCount() throws -> Int {
        entries.count
    }

    // MARK: - Fabrique

    static func summary(for entry: LexicalEntry) -> EntrySummary {
        EntrySummary(
            id: entry.id,
            term: entry.term,
            kind: entry.kind,
            category: entry.category,
            shortDefinition: entry.shortDefinition.value,
            compactGrammar: entry.grammar.compactLabel,
            registerLabel: entry.registerLabel,
            difficulty: entry.difficulty
        )
    }

    /// Normalisation sans accents ni casse, identique à celle attendue de
    /// l'implémentation SQLite : « ephemere » doit trouver « éphémère ».
    static func normalized(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension TestCorpus {
    /// Corpus jouet dont les identifiants suivent l'ordre de création, ce qui
    /// rend les rangs prévisibles dans les assertions.
    static func make(
        perCategory: Int,
        categories: [EntryCategory] = EntryCategory.allCases
    ) -> TestCorpus {
        TestCorpus(entries: categories.flatMap { makeEntries(category: $0, count: perCategory) })
    }

    static func makeEntries(category: EntryCategory, count: Int) -> [LexicalEntry] {
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let term = "terme \(category.rawValue) \(index)"
            let id = EntryID("\(category.rawValue)-\(Self.padded(index))")
            let before = EntryID("\(category.rawValue)-\(Self.padded((index + count - 1) % count))")
            let after = EntryID("\(category.rawValue)-\(Self.padded((index + 1) % count))")
            return LexicalEntry(
                id: id,
                term: term,
                kind: category == .expression ? .expression : .word,
                category: category,
                grammar: GrammarInfo(partOfSpeech: .nomCommun, gender: .masculin),
                registers: [.courant],
                difficulty: 2,
                shortDefinition: EntryText("Définition courte de \(term).", provenance: .editorial),
                longDefinition: EntryText(
                    "Définition longue et précise de \(term), rédigée pour les tests.",
                    provenance: .editorial
                ),
                usageNote: EntryText("S'emploie dans les tests.", provenance: .editorial),
                examples: [Example(text: "Un exemple avec \(term).", origin: .vocabulle)],
                relations: [
                    LexicalRelation(
                        targetID: before,
                        targetTerm: "voisin précédent",
                        type: .contrast,
                        evidence: .editorial,
                        rationale: "Voisin de test, placé avant dans la liste."
                    ),
                    LexicalRelation(
                        targetID: after,
                        targetTerm: "voisin suivant",
                        type: .sameContext,
                        evidence: .editorial,
                        rationale: "Voisin de test, placé après dans la liste."
                    )
                ],
                sources: [
                    SourceRef(
                        kind: .wiktionary,
                        title: term,
                        url: URL(string: "https://fr.wiktionary.org/wiki/\(id.rawValue)"),
                        revisionID: 1,
                        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        license: .ccBySa40
                    )
                ],
                tags: [category.rawValue]
            )
        }
    }

    private static func padded(_ value: Int) -> String {
        String(format: "%03d", value)
    }
}
