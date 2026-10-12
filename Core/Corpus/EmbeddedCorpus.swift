import Foundation

/// Localisation du corpus embarqué dans le bundle.
///
/// L'application **et** l'extension widget ouvrent le même fichier. Il est copié
/// dans les deux bundles par la phase de ressources, plutôt que partagé par un
/// conteneur : un corpus est en lecture seule, il n'a rien à faire dans un
/// conteneur partagé, et le dupliquer évite à l'extension de dépendre d'un
/// entitlement qu'elle n'obtient pas toujours.
public enum EmbeddedCorpus {

    /// Nom du fichier de corpus attendu dans le bundle.
    public static let resourceName = "vocabulle-corpus"
    public static let resourceExtension = "sqlite"

    /// Erreur levée lorsque le corpus n'a pas été embarqué.
    public struct MissingResource: Error, CustomStringConvertible {
        public let bundleIdentifier: String
        public let searchedName: String

        public var description: String {
            "Corpus « \(searchedName) » absent du bundle \(bundleIdentifier). "
            + "La chaîne de production doit être exécutée et le fichier ajouté aux ressources de la cible."
        }
    }

    /// URL du corpus dans le bundle donné.
    ///
    /// Le bundle est un paramètre pour que l'extension passe le sien et pour que
    /// les tests puissent viser un dossier temporaire.
    public static func url(in bundle: Bundle = .main) throws -> URL {
        if let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) {
            return url
        }
        throw MissingResource(
            bundleIdentifier: bundle.bundleIdentifier ?? "inconnu",
            searchedName: "\(resourceName).\(resourceExtension)"
        )
    }

    /// Ouvre le corpus du bundle.
    public static func open(in bundle: Bundle = .main) throws -> SQLiteCorpusStore {
        try SQLiteCorpusStore(url: url(in: bundle))
    }
}
