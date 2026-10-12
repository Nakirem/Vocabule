import Foundation

/// État d'un créneau vis-à-vis de l'utilisateur.
///
/// Le projet demande de distinguer explicitement « planifié », « proposé »,
/// « consulté », « déjà connu » et « favori ». Ces trois premiers sont des états
/// de créneau ; les deux derniers sont des propriétés du terme, valables pour
/// toujours et indépendamment du créneau où il est apparu.
public enum SlotAssignmentStatus: String, Codable, Sendable, CaseIterable {
    /// Réservé pour un créneau futur : le terme est mis de côté, mais
    /// l'utilisateur ne l'a pas vu. Il n'est donc **pas** marqué comme proposé.
    case planned
    /// Affiché : le créneau a commencé, le terme est visible sur l'écran
    /// verrouillé. C'est l'état de tout créneau passé, que l'utilisateur ait
    /// regardé son téléphone ou non — le système ne peut pas le savoir, et
    /// prétendre le contraire serait malhonnête.
    case proposed
    /// L'utilisateur a ouvert la fiche détaillée depuis ce créneau.
    case consulted

    public var displayName: String {
        switch self {
        case .planned: return "Planifié"
        case .proposed: return "Proposé"
        case .consulted: return "Consulté"
        }
    }
}

/// Terme retenu pour un créneau donné.
public struct SlotAssignment: Codable, Hashable, Sendable {
    /// Terme actuellement affiché pour ce créneau.
    public var entryID: EntryID
    public var status: SlotAssignmentStatus
    /// Instant de la décision. Sert à l'élagage de l'historique.
    public var assignedAt: Date
    /// Numéro de tirage dans ce créneau : 0 pour le tirage initial, 1 après un
    /// premier « Autre mot », etc.
    ///
    /// Ce compteur **n'entre pas** dans la graine du tirage : la graine ne
    /// dépend que de la graine utilisateur, du créneau, de la catégorie et du
    /// numéro de tour (`SelectionEngine.nominalEntryID`). Ce qui rend une action
    /// rejouée reproductible, c'est la liste ordonnée des candidats parcourue
    /// toujours dans le même sens, combinée à l'ensemble d'exclusions — dont
    /// font partie `previousEntryIDs`. Rejouer « Autre mot » sur le même état
    /// retombe donc sur le même terme.
    ///
    /// Le compteur sert à l'affichage et au diagnostic : savoir combien de fois
    /// l'utilisateur a demandé à voir autre chose dans ce créneau.
    public var drawSequence: Int
    /// Termes précédemment affichés dans ce créneau, écartés par « Autre mot ».
    ///
    /// Ils ne sont **pas** marqués comme connus : l'utilisateur ne les a pas
    /// rejetés, il a seulement demandé à voir autre chose. Ils ne doivent pas
    /// non plus réapparaître immédiatement.
    public var previousEntryIDs: [EntryID]
    /// `true` si « Déjà connu » a été appliqué depuis ce créneau.
    public var markedKnown: Bool

    public init(
        entryID: EntryID,
        status: SlotAssignmentStatus,
        assignedAt: Date,
        drawSequence: Int = 0,
        previousEntryIDs: [EntryID] = [],
        markedKnown: Bool = false
    ) {
        self.entryID = entryID
        self.status = status
        self.assignedAt = assignedAt
        self.drawSequence = drawSequence
        self.previousEntryIDs = previousEntryIDs
        self.markedKnown = markedKnown
    }
}

/// Réglages de l'utilisateur, stockés avec l'état partagé.
///
/// Ils vivent dans le même fichier que le reste parce que l'extension widget a
/// besoin de la grille horaire et de la politique de fuseau pour déterminer le
/// créneau courant : les séparer obligerait l'extension à lire deux sources.
public struct VocabulleSettings: Codable, Hashable, Sendable {
    public var schedule: SlotSchedule
    public var timeZonePolicy: TimeZonePolicy
    /// Notifications désactivées par défaut, comme demandé.
    public var notificationsEnabled: Bool
    /// Nombre de créneaux futurs réservés d'avance.
    public var plannedAhead: Int

    public init(
        schedule: SlotSchedule = .default,
        timeZonePolicy: TimeZonePolicy = .default,
        notificationsEnabled: Bool = false,
        plannedAhead: Int = 3
    ) {
        self.schedule = schedule
        self.timeZonePolicy = timeZonePolicy
        self.notificationsEnabled = notificationsEnabled
        self.plannedAhead = plannedAhead
    }

    public static let `default` = VocabulleSettings()
}

/// État utilisateur partagé entre l'application et l'extension widget.
///
/// Ce fichier est la **source de vérité unique** du projet : c'est lui qui
/// garantit qu'un même créneau produit le même terme partout et à chaque
/// ouverture. Il est minuscule — quelques dizaines de kilo-octets même après des
/// années d'usage — et ne contient jamais le corpus.
public struct UserState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Compteur monotone. Sert à détecter qu'un écrivain concurrent a modifié
    /// le fichier entre la lecture et l'écriture.
    public var revision: Int
    public var updatedAt: Date

    /// Registre des créneaux, indexé par `SlotID.description`.
    public var assignments: [String: SlotAssignment]
    /// Termes marqués « déjà connu ». Exclus des découvertes jusqu'à ce que
    /// l'utilisateur les décoche.
    public var knownEntryIDs: Set<EntryID>
    /// Favoris. Ne disparaissent jamais, ni à la purge du cache, ni au
    /// changement de version du corpus.
    public var favouriteEntryIDs: Set<EntryID>
    /// Termes dont la fiche a été ouverte au moins une fois.
    public var consultedEntryIDs: Set<EntryID>
    /// Termes déjà proposés au moins une fois, tous créneaux confondus.
    ///
    /// C'est la mémoire qui empêche de reproposer un terme avant d'avoir fait
    /// le tour du corpus. Elle est remise à zéro — en incrémentant `roundCount`
    /// — uniquement lorsque le corpus est épuisé, et l'application le dit alors
    /// explicitement à l'utilisateur.
    public var everProposedEntryIDs: Set<EntryID>
    /// Nombre de fois où le corpus a été parcouru en entier.
    public var roundCount: Int

    /// Graine de sélection, fixée à la première installation.
    ///
    /// Elle est **stockée**, jamais dérivée d'un identifiant d'appareil ou d'un
    /// hachage d'exécution : le tirage doit rester reproductible même après une
    /// réinstallation par AltStore, qui change les identifiants de bundle.
    public var selectionSeed: String

    public var settings: VocabulleSettings
    public var hasCompletedOnboarding: Bool

    public init(
        schemaVersion: Int = UserState.currentSchemaVersion,
        revision: Int = 0,
        updatedAt: Date = Date(timeIntervalSince1970: 0),
        assignments: [String: SlotAssignment] = [:],
        knownEntryIDs: Set<EntryID> = [],
        favouriteEntryIDs: Set<EntryID> = [],
        consultedEntryIDs: Set<EntryID> = [],
        everProposedEntryIDs: Set<EntryID> = [],
        roundCount: Int = 0,
        selectionSeed: String = "",
        settings: VocabulleSettings = .default,
        hasCompletedOnboarding: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.updatedAt = updatedAt
        self.assignments = assignments
        self.knownEntryIDs = knownEntryIDs
        self.favouriteEntryIDs = favouriteEntryIDs
        self.consultedEntryIDs = consultedEntryIDs
        self.everProposedEntryIDs = everProposedEntryIDs
        self.roundCount = roundCount
        self.selectionSeed = selectionSeed
        self.settings = settings
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    /// État initial d'une installation neuve.
    ///
    /// La graine est tirée une fois pour toutes : elle est ensuite recopiée
    /// telle quelle dans chaque sauvegarde, donc sa valeur exacte importe peu,
    /// seule compte sa stabilité.
    public static func initial(seed: String, now: Date) -> UserState {
        UserState(revision: 1, updatedAt: now, selectionSeed: seed)
    }

    public subscript(slot: SlotID) -> SlotAssignment? {
        get { assignments[slot.description] }
        set { assignments[slot.description] = newValue }
    }

    /// Termes actuellement retenus par un créneau planifié ou déjà affiché.
    ///
    /// Utilisé pour ne jamais tirer deux fois le même terme dans deux créneaux
    /// vivants simultanément.
    public var liveEntryIDs: Set<EntryID> {
        var result: Set<EntryID> = []
        for assignment in assignments.values {
            result.insert(assignment.entryID)
            result.formUnion(assignment.previousEntryIDs)
        }
        return result
    }

    /// Termes exclus de tout nouveau tirage.
    public func excludedEntryIDs() -> Set<EntryID> {
        var excluded = knownEntryIDs
        excluded.formUnion(liveEntryIDs)
        excluded.formUnion(everProposedEntryIDs)
        return excluded
    }

    /// Retire les créneaux trop anciens pour alléger le fichier.
    ///
    /// On ne purge que les créneaux **passés et déjà affichés** : un créneau
    /// planifié ou en cours ne doit jamais disparaître, sans quoi l'application
    /// pourrait reproposer un terme déjà réservé. Les favoris, l'historique de
    /// consultation et la mémoire des termes proposés ne sont pas touchés : ils
    /// ne dépendent pas des créneaux.
    public func pruned(keepingPastSlots kept: Int, before cutoff: SlotID) -> UserState {
        var copy = self
        let pastKeys = assignments.compactMap { key, assignment -> String? in
            guard assignment.status != .planned,
                  let slot = SlotID(parsing: key),
                  slot < cutoff
            else { return nil }
            return key
        }.sorted()

        guard pastKeys.count > kept else { return copy }
        for key in pastKeys.prefix(pastKeys.count - kept) {
            copy.assignments.removeValue(forKey: key)
        }
        return copy
    }
}

public extension SlotID {
    /// Analyse la forme textuelle produite par `description`.
    init?(parsing text: String) {
        let parts = text.split(separator: "#")
        guard parts.count == 2,
              let period = DayPeriod(rawValue: String(parts[1]))
        else { return nil }
        let dateParts = parts[0].split(separator: "-")
        guard dateParts.count == 3,
              let year = Int(dateParts[0]),
              let month = Int(dateParts[1]),
              let day = Int(dateParts[2])
        else { return nil }
        self.init(day: LocalDay(year: year, month: month, day: day), period: period)
    }
}
