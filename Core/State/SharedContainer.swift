import Foundation

/// Niveau de partage réellement obtenu entre l'application et son extension.
///
/// Ce n'est pas un détail d'implémentation : c'est une information que
/// l'utilisateur voit dans les réglages, parce qu'elle change ce que le widget
/// peut faire.
public enum SharedContainerTier: String, Codable, Sendable {
    /// Conteneur partagé accessible : l'application et le widget lisent et
    /// écrivent le même fichier d'état.
    case appGroup
    /// Aucun conteneur partagé. L'application reste pleinement fonctionnelle ;
    /// le widget bascule sur une projection calculée, sans état utilisateur.
    ///
    /// On ne crée **jamais** deux magasins privés qui divergeraient en
    /// silence : dans ce mode, le widget n'écrit rien et ne lit aucun état
    /// privé, il recalcule le terme du créneau à partir du corpus embarqué.
    case isolated

    public var displayName: String {
        switch self {
        case .appGroup: return "Partagé"
        case .isolated: return "Isolé"
        }
    }
}

/// Emplacement de stockage de l'état partagé.
///
/// # Pourquoi ce type existe
///
/// Vocabulle est prévu pour être installé via AltStore Classic avec un compte
/// Apple gratuit. Or un profil de provisionnement délivré à un compte gratuit
/// ne contient pas l'entitlement `com.apple.security.application-groups` :
/// `containerURL(forSecurityApplicationGroupIdentifier:)` renvoie alors `nil`,
/// **sans erreur**. Une application qui suppose le conteneur disponible se
/// contente d'afficher un widget vide, sans jamais expliquer pourquoi.
///
/// Ce type rend le cas explicite : il tente le conteneur partagé, et s'il
/// n'existe pas, il le dit (`tier == .isolated`) au lieu de retomber en silence
/// sur un répertoire privé qui donnerait un widget divergent.
public struct SharedContainer: Sendable {
    public let tier: SharedContainerTier
    /// Répertoire où lire et écrire l'état.
    public let directory: URL
    /// Identifiant de groupe effectivement obtenu, lorsqu'il y en a un.
    public let groupIdentifier: String?
    /// Identifiants tentés, dans l'ordre. Utile au diagnostic affiché dans les
    /// réglages : l'utilisateur voit ce qui a été essayé.
    public let attemptedGroupIdentifiers: [String]

    public init(
        tier: SharedContainerTier,
        directory: URL,
        groupIdentifier: String? = nil,
        attemptedGroupIdentifiers: [String] = []
    ) {
        self.tier = tier
        self.directory = directory
        self.groupIdentifier = groupIdentifier
        self.attemptedGroupIdentifiers = attemptedGroupIdentifiers
    }

    /// Nom du fichier d'état.
    public static let stateFileName = "state.json"
    /// Sous-répertoire du cache de corpus (purgeable).
    public static let cacheDirectoryName = "CorpusCache"

    public var stateURL: URL {
        directory.appendingPathComponent(Self.stateFileName)
    }

    public var cacheDirectory: URL {
        directory.appendingPathComponent(Self.cacheDirectoryName, isDirectory: true)
    }
}

public extension SharedContainer {
    /// Identifiant de groupe déclaré dans les entitlements du projet.
    ///
    /// AltStore ajoute le préfixe d'équipe au moment de la signature
    /// (`group.fr.vocabulle.app.ABCDE12345`) et publie la valeur réellement
    /// obtenue dans `ALTAppGroups`. C'est donc cette clé qu'il faut lire en
    /// premier : celle-ci ne sert que de repli.
    static let declaredGroupIdentifier = "group.fr.vocabulle.app"

    /// Résout le conteneur disponible pour un bundle donné.
    ///
    /// - Parameters:
    ///   - bundle: bundle de l'appelant. L'extension passe le sien.
    ///   - fallbackDirectory: répertoire privé de repli ; injectable pour les
    ///     tests, qui écrivent dans un dossier temporaire.
    ///   - containerURLProvider: injection utilisée par les tests, qui ne
    ///     peuvent pas obtenir de conteneur partagé.
    static func resolve(
        bundle: Bundle = .main,
        fallbackDirectory: URL? = nil,
        containerURLProvider: (String) -> URL? = { identifier in
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        }
    ) -> SharedContainer {
        let candidates = candidateGroupIdentifiers(bundle: bundle)
        for identifier in candidates {
            if let url = containerURLProvider(identifier) {
                return SharedContainer(
                    tier: .appGroup,
                    directory: url,
                    groupIdentifier: identifier,
                    attemptedGroupIdentifiers: candidates
                )
            }
        }
        return SharedContainer(
            tier: .isolated,
            directory: fallbackDirectory ?? defaultFallbackDirectory(bundle: bundle),
            groupIdentifier: nil,
            attemptedGroupIdentifiers: candidates
        )
    }

    /// Identifiants à essayer, du plus fiable au moins fiable.
    ///
    /// `ALTAppGroups` d'abord parce qu'il contient la valeur signée ; puis
    /// l'identifiant déclaré, pour le cas d'une installation par Xcode avec un
    /// compte payant, où AltStore n'est pas intervenu.
    static func candidateGroupIdentifiers(bundle: Bundle) -> [String] {
        var candidates: [String] = []
        let info = bundle.infoDictionary
        if let altGroups = info?["ALTAppGroups"] as? [String] {
            candidates.append(contentsOf: altGroups)
        } else if let altGroup = info?["ALTAppGroups"] as? String {
            candidates.append(altGroup)
        }
        candidates.append(declaredGroupIdentifier)

        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Répertoire privé utilisé lorsque aucun conteneur partagé n'existe.
    ///
    /// L'application seule écrit ici. Le widget ne le lit pas : il lui
    /// préférerait un état divergent, ce qui est précisément l'erreur que ce
    /// type existe pour éviter.
    static func defaultFallbackDirectory(bundle: Bundle) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let identifier = bundle.bundleIdentifier ?? "fr.vocabulle.app"
        return base.appendingPathComponent(identifier, isDirectory: true)
    }
}
