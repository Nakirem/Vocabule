import Foundation

/// Liens profonds de l'application.
///
/// Le widget ouvre `vocabulle://terme/<identifiant>` : c'est le mécanisme qui
/// garantit que toucher l'écran verrouillé ouvre **exactement** le terme
/// affiché, même si le créneau a changé entre l'affichage et le toucher. Le lien
/// porte donc l'identifiant de la fiche, jamais « le terme courant ».
public enum DeepLink: Hashable, Sendable {
    /// Ouvre la fiche d'un terme précis.
    case entry(EntryID)
    /// Ouvre l'onglet Aujourd'hui.
    case today

    public static let scheme = "vocabulle"
    public static let host = "terme"

    /// Construit le lien d'une fiche.
    public static func url(for entryID: EntryID) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        // Le chemin, et non le paramètre de requête : l'identifiant est un slug
        // ASCII sans caractère réservé, il n'a rien à faire dans une chaîne de
        // requête qui devrait être percent-encodée puis décodée.
        components.path = "/\(host)/\(entryID.rawValue)"
        return components.url ?? URL(string: "\(scheme)://\(host)/\(entryID.rawValue)")!
    }

    /// Analyse une URL entrante. Renvoie `nil` pour toute URL étrangère.
    public init?(url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        let pieces = url.path.split(separator: "/").map(String.init)
        if pieces.count == 2, pieces[0] == Self.host, !pieces[1].isEmpty {
            self = .entry(EntryID(pieces[1]))
            return
        }
        // `vocabulle://terme/monomaniaque` place « terme » dans `host` et le
        // slug dans le chemin : les deux écritures doivent fonctionner, car
        // certaines versions d'iOS traitent différemment une autorité suivie
        // d'un chemin.
        if let host = url.host, host == Self.host, pieces.count == 1, !pieces[0].isEmpty {
            self = .entry(EntryID(pieces[0]))
            return
        }
        if url.host == "aujourdhui" || pieces.first == "aujourdhui" {
            self = .today
            return
        }
        return nil
    }
}
