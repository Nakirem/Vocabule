import Foundation

public extension Calendar {
    /// Calendrier grégorien de référence du projet.
    ///
    /// Volontairement indépendant du calendrier système : si l'utilisateur a
    /// choisi un calendrier non grégorien, « 08:00 » ne désignerait plus le même
    /// instant, et les créneaux enregistrés deviendraient incomparables.
    static var vocabulle: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "fr_FR")
        return calendar
    }
}

/// Source de temps injectable.
///
/// Toute la logique de créneaux passe par cette abstraction : les tests peuvent
/// donc simuler un changement d'heure, un passage de minuit ou une horloge qui
/// recule, sans toucher à l'horloge du système.
public protocol Clock: Sendable {
    var now: Date { get }
}

/// Horloge réelle.
public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

/// Horloge figée, utilisée par les tests et les aperçus.
public struct FixedClock: Clock {
    public let now: Date

    public init(_ now: Date) {
        self.now = now
    }

    /// Construit une horloge à partir d'une date ISO 8601 (`2026-10-12T07:30:00Z`).
    public init?(iso8601: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso8601) else { return nil }
        self.now = date
    }
}

/// Défaut détecté dans une grille horaire.
public enum ScheduleIssue: Hashable, Sendable, CustomStringConvertible {
    case notStrictlyIncreasing

    public var description: String {
        switch self {
        case .notStrictlyIncreasing:
            return "Les trois heures doivent être strictement croissantes dans la journée."
        }
    }
}

/// Heures des trois créneaux quotidiens.
///
/// Les valeurs par défaut sont 08:00, 14:00 et 20:00. La grille doit rester
/// strictement croissante : si l'après-midi passe avant le matin, la règle
/// « le créneau actif est le dernier commencé » n'a plus de sens et le mot du
/// soir ne pourrait plus couvrir la nuit.
public struct SlotSchedule: Hashable, Codable, Sendable {
    public static let defaultMorning = TimeOfDay(hour: 8)
    public static let defaultAfternoon = TimeOfDay(hour: 14)
    public static let defaultEvening = TimeOfDay(hour: 20)

    /// Grille par défaut appliquée à la première installation.
    public static let `default` = SlotSchedule(
        morning: defaultMorning,
        afternoon: defaultAfternoon,
        evening: defaultEvening
    )

    public var morning: TimeOfDay
    public var afternoon: TimeOfDay
    public var evening: TimeOfDay

    public init(morning: TimeOfDay, afternoon: TimeOfDay, evening: TimeOfDay) {
        self.morning = morning
        self.afternoon = afternoon
        self.evening = evening
    }

    public func time(for period: DayPeriod) -> TimeOfDay {
        switch period {
        case .morning: return morning
        case .afternoon: return afternoon
        case .evening: return evening
        }
    }

    public subscript(period: DayPeriod) -> TimeOfDay {
        get { time(for: period) }
        set {
            switch period {
            case .morning: morning = newValue
            case .afternoon: afternoon = newValue
            case .evening: evening = newValue
            }
        }
    }

    public var orderedTimes: [TimeOfDay] { [morning, afternoon, evening] }

    /// `true` si les heures sont strictement croissantes.
    public var isStrictlyIncreasing: Bool {
        morning < afternoon && afternoon < evening
    }

    public func validationIssues() -> [ScheduleIssue] {
        isStrictlyIncreasing ? [] : [.notStrictlyIncreasing]
    }

    /// Grille corrigée pour être utilisable.
    ///
    /// Appelée après une saisie utilisateur : on ne refuse pas l'enregistrement
    /// (l'interface empêche déjà les cas absurdes), on décale ce qui doit
    /// l'être pour ne jamais se retrouver avec un moteur de créneaux incohérent.
    /// L'utilisateur voit la valeur corrigée dans les réglages.
    public func normalized() -> SlotSchedule {
        var result = self
        if result.afternoon <= result.morning {
            result.afternoon = TimeOfDay(
                hour: result.morning.hour,
                minute: min(result.morning.minute + 1, 59)
            )
        }
        if result.evening <= result.afternoon {
            result.evening = TimeOfDay(
                hour: result.afternoon.hour,
                minute: min(result.afternoon.minute + 1, 59)
            )
        }
        // Cas extrême : trois créneaux collés à 23:5x. On retombe sur la grille
        // par défaut plutôt que de produire une journée sans créneau valide.
        if !result.isStrictlyIncreasing {
            return .default
        }
        return result
    }
}

/// Traduit un instant en créneau, et inversement.
///
/// Règle centrale du projet : **le créneau actif est le dernier créneau
/// commencé**. Conséquence directe : après minuit et avant le créneau du matin,
/// le créneau actif est encore le créneau du soir de la veille. C'est ce qui
/// fait que la découverte du soir reste affichée toute la nuit, comme demandé.
public struct SlotResolver: Sendable {
    public var schedule: SlotSchedule
    public var timeZonePolicy: TimeZonePolicy
    public var calendar: Calendar
    /// Fuseau de l'appareil, injecté pour que les tests ne dépendent pas de la
    /// machine qui les exécute.
    public var deviceTimeZone: TimeZone

    public init(
        schedule: SlotSchedule = .default,
        timeZonePolicy: TimeZonePolicy = .default,
        calendar: Calendar = .vocabulle,
        deviceTimeZone: TimeZone = .current
    ) {
        self.schedule = schedule
        self.timeZonePolicy = timeZonePolicy
        self.calendar = calendar
        self.deviceTimeZone = deviceTimeZone
    }

    /// Fuseau effectivement utilisé pour placer les créneaux.
    public var timeZone: TimeZone {
        timeZonePolicy.resolvedTimeZone(deviceTimeZone: deviceTimeZone)
    }

    private var zonedCalendar: Calendar {
        var calendar = self.calendar
        calendar.timeZone = timeZone
        return calendar
    }

    /// Instant de début d'un créneau.
    ///
    /// Passe par `date(bySettingHour:…)` plutôt que par une addition de secondes :
    /// lors du passage à l'heure d'été, l'heure demandée peut ne pas exister
    /// (02:30 en Europe/Paris le dernier dimanche de mars). La politique
    /// `.nextTimePreservingSmallerComponents` décale alors d'une heure au lieu
    /// de renvoyer `nil` ou de sauter au lendemain.
    public func startDate(of slot: SlotID) -> Date? {
        let calendar = zonedCalendar
        var dayComponents = DateComponents()
        dayComponents.year = slot.day.year
        dayComponents.month = slot.day.month
        dayComponents.day = slot.day.day
        guard let dayStart = calendar.date(from: dayComponents) else { return nil }

        let time = schedule.time(for: slot.period)
        if let matched = calendar.date(
            bySettingHour: time.hour,
            minute: time.minute,
            second: 0,
            of: dayStart,
            matchingPolicy: .nextTimePreservingSmallerComponents,
            repeatedTimePolicy: .first,
            direction: .forward
        ) {
            return matched
        }
        // Repli : minuit local plus le décalage nominal. Ne devrait jamais
        // arriver, mais une découverte doit rester affichable même si la base de
        // fuseaux de l'appareil est incomplète.
        return dayStart.addingTimeInterval(TimeInterval(time.minutesFromMidnight * 60))
    }

    /// Fin d'un créneau : début du suivant.
    public func endDate(of slot: SlotID) -> Date? {
        startDate(of: slot.next)
    }

    /// Créneau actif à un instant donné.
    public func currentSlot(at date: Date) -> SlotID {
        let day = LocalDay(date: date, in: timeZone, calendar: calendar)
        // Du plus tard au plus tôt : le premier créneau déjà commencé gagne.
        for period in [DayPeriod.evening, .afternoon, .morning] {
            let candidate = SlotID(day: day, period: period)
            if let start = startDate(of: candidate), date >= start {
                return candidate
            }
        }
        // Avant le créneau du matin : on est encore dans la soirée de la veille.
        return SlotID(day: day.previous(calendar: calendar), period: .evening)
    }

    /// Débuts des prochains créneaux, strictement postérieurs à `date`.
    ///
    /// Sert à construire la chronologie du widget : chaque entrée doit
    /// correspondre à un changement de terme, jamais à un rafraîchissement
    /// inutile.
    public func upcomingStartDates(after date: Date, count: Int) -> [Date] {
        guard count > 0 else { return [] }
        var results: [Date] = []
        var cursor = currentSlot(at: date)
        // Borne de sécurité : chaque itération avance d'au moins un créneau,
        // mais on préfère une boucle bornée à une boucle qui ne termine pas.
        let maxIterations = count * 3 + 6
        var iterations = 0
        while results.count < count, iterations < maxIterations {
            iterations += 1
            if let start = startDate(of: cursor), start > date {
                results.append(start)
            }
            cursor = cursor.next
        }
        return results
    }

    /// Les `count` derniers créneaux jusqu'à `date` inclus, du plus ancien au
    /// plus récent.
    public func recentSlots(endingAt date: Date, count: Int) -> [SlotID] {
        guard count > 0 else { return [] }
        var slots: [SlotID] = [currentSlot(at: date)]
        while slots.count < count {
            guard let first = slots.first else { break }
            slots.insert(first.previous, at: 0)
        }
        return slots
    }

    /// Durée nominale d'un créneau, à titre indicatif pour l'interface.
    public func nominalDuration(of period: DayPeriod) -> TimeInterval {
        let start = schedule.time(for: period).minutesFromMidnight
        let end = schedule.time(for: period.next).minutesFromMidnight
        let minutes = end > start ? end - start : (24 * 60 - start) + end
        return TimeInterval(minutes * 60)
    }
}
