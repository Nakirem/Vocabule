import Foundation
import UserNotifications

/// Rappels quotidiens facultatifs.
///
/// Désactivés par défaut, comme demandé. L'application ne demande
/// l'autorisation qu'au moment où l'utilisateur active lui-même l'interrupteur :
/// afficher une demande d'autorisation au premier lancement, avant que
/// l'utilisateur sache ce que fait l'application, est une pratique qu'on refuse.
///
/// Le texte du rappel ne révèle jamais le terme : il annonce qu'une découverte
/// attend. Afficher le mot sur l'écran verrouillé priverait de l'effet de
/// surprise que l'application cherche à créer.
public struct NotificationScheduler: Sendable {

    public static let identifierPrefix = "vocabulle.creneau."

    public init() {}

    /// État courant de l'autorisation, sans jamais la demander.
    public func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Demande l'autorisation. Renvoie `false` si elle est refusée.
    public func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            // Un refus ou une erreur système ne doit pas faire échouer
            // l'activation : l'appelant réaffiche simplement l'interrupteur
            // dans sa position réelle.
            return false
        }
    }

    /// Reprogramme les trois rappels, en remplaçant les précédents.
    ///
    /// Les déclencheurs sont des `UNCalendarNotificationTrigger` répétés : ils
    /// se répètent chaque jour à l'heure locale de l'appareil, sans qu'aucun
    /// calcul de date n'ait à être refait. Un utilisateur qui change l'heure
    /// d'un créneau doit voir ses rappels suivre : on retire donc toutes les
    /// demandes connues avant d'ajouter les nouvelles, plutôt que d'ajouter par
    /// identifiant au risque d'en oublier une.
    public func schedule(_ schedule: SlotSchedule) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: allIdentifiers())

        for period in DayPeriod.allCases {
            let time = schedule.time(for: period)
            let content = UNMutableNotificationContent()
            content.title = "Votre mot du \(period.lowercaseName)"
            content.body = "Une nouvelle découverte vous attend dans Vocabulle."
            content.sound = .default

            var components = DateComponents()
            components.hour = time.hour
            components.minute = time.minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let request = UNNotificationRequest(
                identifier: identifier(for: period),
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
            } catch {
                // On continue avec les autres créneaux : un rappel manquant vaut
                // mieux que trois rappels manquants.
                continue
            }
        }
    }

    /// Retire tous les rappels de l'application.
    public func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: allIdentifiers())
    }

    /// Identifiants des rappels en attente, pour le diagnostic dans les réglages.
    public func pendingIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
            .sorted()
    }

    public func identifier(for period: DayPeriod) -> String {
        Self.identifierPrefix + period.rawValue
    }

    private func allIdentifiers() -> [String] {
        DayPeriod.allCases.map(identifier(for:))
    }
}
