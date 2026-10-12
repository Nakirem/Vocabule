import Foundation

/// Les trois moments de la journée qui portent une découverte.
public enum DayPeriod: String, Codable, CaseIterable, Sendable {
    case morning
    case afternoon
    case evening

    /// Ordre chronologique dans une journée.
    public var order: Int {
        switch self {
        case .morning: return 0
        case .afternoon: return 1
        case .evening: return 2
        }
    }

    public var displayName: String {
        switch self {
        case .morning: return "Matin"
        case .afternoon: return "Après-midi"
        case .evening: return "Soir"
        }
    }

    /// Nom utilisé dans les phrases (« la découverte du matin »).
    public var lowercaseName: String {
        switch self {
        case .morning: return "matin"
        case .afternoon: return "après-midi"
        case .evening: return "soir"
        }
    }

    public var symbolName: String {
        switch self {
        case .morning: return "sunrise"
        case .afternoon: return "sun.max"
        case .evening: return "moon.stars"
        }
    }

    /// Période précédente dans l'ordre chronologique, en remontant la veille.
    public var previous: DayPeriod {
        switch self {
        case .morning: return .evening
        case .afternoon: return .morning
        case .evening: return .afternoon
        }
    }

    public var next: DayPeriod {
        switch self {
        case .morning: return .afternoon
        case .afternoon: return .evening
        case .evening: return .morning
        }
    }
}

/// Un jour civil dans le fuseau de référence.
///
/// On ne stocke volontairement pas un `Date` : une date absolue change de jour
/// civil selon le fuseau, et l'historique doit rester lisible même si
/// l'utilisateur change de fuseau ou voyage. Le jour civil est ce que
/// l'utilisateur a vu.
public struct LocalDay: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(date: Date, in timeZone: TimeZone, calendar: Calendar = .vocabulle) {
        var calendar = calendar
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.year = components.year ?? 1970
        self.month = components.month ?? 1
        self.day = components.day ?? 1
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Représentation ISO 8601 courte (`2026-10-12`).
    public var iso8601: String { description }

    public static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Jour précédent dans le calendrier grégorien.
    public func previous(calendar: Calendar = .vocabulle) -> LocalDay {
        adding(days: -1, calendar: calendar)
    }

    public func adding(days: Int, calendar: Calendar = .vocabulle) -> LocalDay {
        var calendar = calendar
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let base = calendar.date(from: components),
              let shifted = calendar.date(byAdding: .day, value: days, to: base)
        else {
            return self
        }
        return LocalDay(date: shifted, in: calendar.timeZone, calendar: calendar)
    }
}

/// Identité d'un créneau : un jour civil et un moment de la journée.
///
/// C'est la clé de tout le reste. Le moteur de sélection écrit dans un registre
/// indexé par `SlotID` ; l'application et l'extension widget lisent le même
/// registre. Deux processus ou deux ouvertures à la même heure obtiennent donc
/// forcément le même terme pour un créneau donné, sans avoir à recalculer quoi
/// que ce soit.
///
/// La forme textuelle (`2026-10-12#evening`) est volontairement stable : elle
/// sert de clé de dictionnaire dans le fichier d'état partagé.
public struct SlotID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let day: LocalDay
    public let period: DayPeriod

    public init(day: LocalDay, period: DayPeriod) {
        self.day = day
        self.period = period
    }

    public var description: String { "\(day.iso8601)#\(period.rawValue)" }

    public static func < (lhs: SlotID, rhs: SlotID) -> Bool {
        if lhs.day != rhs.day { return lhs.day < rhs.day }
        return lhs.period.order < rhs.period.order
    }

    /// Créneau immédiatement précédent, en remontant la veille si nécessaire.
    public var previous: SlotID {
        if period == .morning {
            return SlotID(day: day.previous(), period: .evening)
        }
        return SlotID(day: day, period: period.previous)
    }

    /// Créneau immédiatement suivant, en passant au lendemain si nécessaire.
    public var next: SlotID {
        if period == .evening {
            return SlotID(day: day.adding(days: 1), period: .morning)
        }
        return SlotID(day: day, period: period.next)
    }
}

/// Heure locale dans une journée, exprimée en heures et minutes.
///
/// On n'utilise pas `Date` pour représenter « 08:00 » : une heure de créneau est
/// une intention de l'utilisateur (« je veux ma découverte à huit heures »), pas
/// un instant absolu. C'est le résolveur qui la projette sur un fuseau.
public struct TimeOfDay: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int = 0) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    public var minutesFromMidnight: Int { hour * 60 + minute }

    /// Forme textuelle stable (`08:00`), utilisée comme clé de stockage.
    public var description: String { String(format: "%02d:%02d", hour, minute) }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesFromMidnight < rhs.minutesFromMidnight
    }

    /// Analyse une chaîne `HH:mm`. Renvoie `nil` si la forme est invalide.
    public init?(parse text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        self.init(hour: hour, minute: minute)
    }

    /// Affichage respectant les réglages système de l'appareil.
    public func formatted(locale: Locale = .current) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let reference = Calendar.vocabulle.date(from: components) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: reference)
    }
}

/// Politique de fuseau horaire retenue par l'utilisateur.
public enum TimeZonePolicy: Hashable, Codable, Sendable {
    /// Suit le fuseau de l'appareil. Convient aux personnes qui voyagent.
    case device
    /// Fuseau fixe identifié par son nom IANA.
    case fixed(identifier: String)

    /// Politique par défaut à l'installation : heure de Paris.
    public static let `default` = TimeZonePolicy.fixed(identifier: "Europe/Paris")

    /// Fuseau effectif pour une date donnée.
    ///
    /// `TimeZone(identifier:)` peut renvoyer `nil` si la base de fuseaux ne
    /// connaît pas l'identifiant (identifiant obsolète, base tronquée). On
    /// retombe alors sur le fuseau de l'appareil plutôt que de planter : une
    /// découverte affichée à une heure légèrement décalée reste préférable à une
    /// application qui ne s'ouvre plus.
    public func resolvedTimeZone(deviceTimeZone: TimeZone = .current) -> TimeZone {
        switch self {
        case .device:
            return deviceTimeZone
        case .fixed(let identifier):
            return TimeZone(identifier: identifier) ?? deviceTimeZone
        }
    }

    public var displayName: String {
        switch self {
        case .device:
            return "Fuseau de l'appareil"
        case .fixed(let identifier):
            return identifier
        }
    }
}
