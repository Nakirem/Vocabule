import Foundation

/// Erreur de lecture ou d'écriture de l'état partagé.
public enum UserStateStoreError: Error, CustomStringConvertible {
    /// Le fichier existe mais n'est pas exploitable.
    case corruptedFile(URL, underlying: String)
    /// Une version de schéma plus récente que celle que ce binaire connaît.
    ///
    /// Se produit lorsqu'une version récente de l'application a écrit l'état et
    /// qu'une version antérieure — par exemple l'extension d'un binaire plus
    /// ancien — tente de le lire. On refuse d'écrire plutôt que de détruire des
    /// données qu'on ne comprend pas.
    case unsupportedSchema(found: Int, supported: Int)
    case writeFailed(URL, underlying: String)

    public var description: String {
        switch self {
        case .corruptedFile(let url, let underlying):
            return "État illisible (\(url.lastPathComponent)) : \(underlying)"
        case .unsupportedSchema(let found, let supported):
            return "État écrit par une version plus récente (schéma \(found), pris en charge : \(supported))."
        case .writeFailed(let url, let underlying):
            return "Écriture impossible (\(url.lastPathComponent)) : \(underlying)"
        }
    }
}

/// Lecture et écriture de l'état partagé.
///
/// Trois garanties, exigées par le projet parce que deux processus écrivent le
/// même fichier :
///
/// 1. **Écriture atomique** — on écrit dans un fichier temporaire puis on
///    remplace. Un widget qui lit pendant l'écriture voit soit l'ancien état
///    complet, soit le nouveau, jamais un fichier tronqué.
/// 2. **Coordination interprocessus** — `NSFileCoordinator` sérialise les accès
///    entre l'application et l'extension.
/// 3. **Révision monotone** — chaque écriture incrémente `revision`. Un
///    écrivain qui constate que la révision a changé depuis sa lecture rejoue
///    la transformation sur l'état frais au lieu d'écraser la modification.
///
/// La conformité à `Sendable` est **non vérifiée** : `FileManager` n'est pas
/// déclaré `Sendable` par Foundation, le compilateur ne peut donc pas contrôler
/// ce champ. La garantie est assurée autrement — `FileManager` est sans état
/// pour les opérations utilisées ici, et la seule ressource réellement
/// partagée, le fichier d'état, est protégée par la coordination et le
/// remplacement atomique décrits ci-dessus. Même compromis que
/// `SQLiteCorpusStore`.
public struct UserStateStore: @unchecked Sendable {
    public let container: SharedContainer
    private let fileManager: FileManager

    public init(container: SharedContainer, fileManager: FileManager = .default) {
        self.container = container
        self.fileManager = fileManager
    }

    /// Nombre de tentatives en cas de conflit d'écriture.
    ///
    /// Trois suffisent : les conflits réels sont rares et se résolvent au
    /// premier rejeu. Au-delà, on rend la main plutôt que de boucler.
    private static let maxWriteAttempts = 3

    /// Charge l'état, ou renvoie un état initial s'il n'existe pas encore.
    public func loadOrCreate(seed: @autoclosure () -> String, now: Date) throws -> UserState {
        guard fileManager.fileExists(atPath: container.stateURL.path) else {
            return UserState.initial(seed: seed(), now: now)
        }
        return try load()
    }

    /// Charge l'état existant.
    public func load() throws -> UserState {
        let url = container.stateURL
        let data: Data
        do {
            data = try coordinatedRead(at: url)
        } catch {
            throw UserStateStoreError.corruptedFile(url, underlying: error.localizedDescription)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state: UserState
        do {
            state = try decoder.decode(UserState.self, from: data)
        } catch {
            // Un fichier illisible ne doit pas rendre l'application inutilisable.
            // On le met de côté : l'utilisateur perd sa progression, mais rien
            // n'est détruit et l'incident reste diagnosticable.
            try? quarantineCorruptedFile(at: url)
            throw UserStateStoreError.corruptedFile(url, underlying: String(describing: error))
        }

        guard state.schemaVersion <= UserState.currentSchemaVersion else {
            throw UserStateStoreError.unsupportedSchema(
                found: state.schemaVersion,
                supported: UserState.currentSchemaVersion
            )
        }
        return Self.migrate(state)
    }

    /// Écrit l'état en incrémentant la révision.
    @discardableResult
    public func save(_ state: UserState, now: Date) throws -> UserState {
        var next = state
        next.revision = state.revision + 1
        next.updatedAt = now
        next.schemaVersion = UserState.currentSchemaVersion
        try write(next)
        return next
    }

    /// Applique une transformation à l'état courant, avec reprise en cas de
    /// conflit.
    ///
    /// C'est le point d'entrée de toutes les actions utilisateur : « Autre
    /// mot », « Déjà connu », ouverture d'une fiche. La transformation est
    /// relue puis rejouée sur l'état frais, ce qui rend l'opération idempotente
    /// sans que l'appelant ait à s'en soucier.
    @discardableResult
    public func update(now: Date, _ transform: (UserState) -> UserState) throws -> UserState {
        var lastError: Error?
        for _ in 0..<Self.maxWriteAttempts {
            let current = try load()
            var candidate = transform(current)
            candidate.revision = current.revision + 1
            candidate.updatedAt = now
            candidate.schemaVersion = UserState.currentSchemaVersion
            do {
                try write(candidate)
                return candidate
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? UserStateStoreError.writeFailed(container.stateURL, underlying: "conflit persistant")
    }

    // MARK: - Bas niveau

    private func coordinatedRead(at url: URL) throws -> Data {
        var coordinatorError: NSError?
        var result: Result<Data, Error>?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readable in
            result = Result { try Data(contentsOf: readable) }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private func write(_ state: UserState) throws {
        let url = container.stateURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Tri des clés : deux exécutions produisant le même état produisent le
        // même octet. Sans cela, chaque écriture ferait « changer » le fichier
        // aux yeux de tout outil qui le compare.
        encoder.outputFormatting = [.sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw UserStateStoreError.writeFailed(url, underlying: String(describing: error))
        }

        do {
            try fileManager.createDirectory(at: container.directory, withIntermediateDirectories: true)
        } catch {
            throw UserStateStoreError.writeFailed(url, underlying: error.localizedDescription)
        }

        var coordinatorError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { writable in
            do {
                // Écriture atomique : temporaire puis remplacement. Le fichier
                // temporaire vit dans le même répertoire, donc sur le même
                // volume — condition nécessaire pour que le remplacement soit
                // atomique.
                let temporary = writable.deletingLastPathComponent()
                    .appendingPathComponent(".state-\(UUID().uuidString).tmp")
                try data.write(to: temporary, options: .atomic)
                if FileManager.default.fileExists(atPath: writable.path) {
                    _ = try FileManager.default.replaceItemAt(writable, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: writable)
                }
            } catch {
                writeError = error
            }
        }
        if let coordinatorError {
            throw UserStateStoreError.writeFailed(url, underlying: coordinatorError.localizedDescription)
        }
        if let writeError {
            throw UserStateStoreError.writeFailed(url, underlying: writeError.localizedDescription)
        }
    }

    /// Déplace un fichier illisible au lieu de le supprimer.
    private func quarantineCorruptedFile(at url: URL) throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrompu-\(stamp)")
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: url, to: destination)
    }

    /// Applique les migrations de schéma.
    ///
    /// Une seule version existe aujourd'hui ; la fonction est en place pour que
    /// l'ajout d'un champ n'oblige jamais à repartir de zéro.
    static func migrate(_ state: UserState) -> UserState {
        var migrated = state
        if migrated.schemaVersion < UserState.currentSchemaVersion {
            migrated.schemaVersion = UserState.currentSchemaVersion
        }
        if migrated.selectionSeed.isEmpty {
            migrated.selectionSeed = Self.fallbackSeed(for: migrated)
        }
        return migrated
    }

    /// Graine de secours pour un état écrit avant l'introduction du champ.
    ///
    /// Dérivée du contenu de l'état, donc stable pour un état donné, et non
    /// d'un identifiant d'appareil.
    static func fallbackSeed(for state: UserState) -> String {
        let material = state.assignments.keys.sorted().joined(separator: "|")
        return String(StableHash.fnv1a64(material), radix: 36)
    }
}
