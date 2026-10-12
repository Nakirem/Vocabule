import Foundation

/// Mise en forme des dates, en français.
///
/// L'interface est entièrement en français, y compris sur un téléphone réglé en
/// anglais. On force donc la locale au lieu de suivre celle de l'appareil :
/// afficher « Tuesday 13 October » au milieu de textes français serait
/// incohérent. Les nombres et les heures suivent la même règle.
///
/// Le fuseau, lui, n'est jamais forcé : il vient des réglages de l'utilisateur,
/// parce qu'une découverte est liée à une heure locale choisie.
enum FrenchFormat {

    static let locale = Locale(identifier: "fr_FR")

    /// « mardi 13 octobre ».
    static func day(_ date: Date, timeZone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// « 13 octobre 2026 ».
    static func calendarDay(_ date: Date, timeZone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.wide).year()
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// « 08:00 », dans le fuseau donné.
    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// Heure d'un créneau, exprimée dans le fuseau de l'utilisateur.
    ///
    /// Un créneau est une heure locale voulue (« je veux ma découverte à huit
    /// heures ») : on l'affiche donc telle qu'elle a été saisie, sans conversion.
    static func slotTime(_ time: TimeOfDay) -> String {
        time.formatted(locale: locale)
    }
}
