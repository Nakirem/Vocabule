import Foundation
@testable import VocabulleCore

/// Dates de référence des tests.
///
/// Tout est construit en heure de Paris explicitement. Utiliser `Date()` ou le
/// fuseau de la machine rendrait les tests dépendants de l'environnement de la
/// CI, ce qui est exactement le genre de fragilité qu'on ne veut pas sur un
/// projet dont le cœur est temporel.
enum ParisTime {
    static let zone = TimeZone(identifier: "Europe/Paris")!

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = Locale(identifier: "fr_FR")
        return calendar
    }()

    /// Instant à partir de composantes exprimées en heure de Paris.
    static func instant(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = zone
        return calendar.date(from: components)!
    }
}

/// Instant à partir de composantes UTC.
///
/// Indispensable pour les tests de changement d'heure : pendant l'heure
/// répétée du mois d'octobre, une heure locale désigne deux instants distincts,
/// et une heure locale de mars peut ne pas exister du tout. Passer par UTC lève
/// toute ambiguïté.
enum UTCTime {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func instant(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(identifier: "UTC")
        return calendar.date(from: components)!
    }
}

/// Crée un dossier temporaire propre à un test.
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("vocabulle-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Supprime un dossier temporaire sans faire échouer le test s'il a déjà disparu.
func removeTemporaryDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}
