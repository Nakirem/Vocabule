import SwiftUI

/// Écran Réglages.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var morning = Date()
    @State private var afternoon = Date()
    @State private var evening = Date()
    @State private var didLoadSchedule = false

    var body: some View {
        NavigationStack {
            Form {
                scheduleSection
                timeZoneSection
                notificationsSection
                corpusSection
                sharingSection
                usageSection

                if let notice = environment.notice {
                    Section {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(VocabulleTheme.caution)
                    }
                }
            }
            .navigationTitle("Réglages")
            .task {
                guard !didLoadSchedule else { return }
                let schedule = environment.settings.schedule
                morning = date(from: schedule.morning)
                afternoon = date(from: schedule.afternoon)
                evening = date(from: schedule.evening)
                didLoadSchedule = true
            }
        }
    }

    // MARK: - Heures

    private var scheduleSection: some View {
        Section {
            DatePicker("Matin", selection: $morning, displayedComponents: .hourAndMinute)
                .onChange(of: morning) { _, _ in commitSchedule() }
            DatePicker("Après-midi", selection: $afternoon, displayedComponents: .hourAndMinute)
                .onChange(of: afternoon) { _, _ in commitSchedule() }
            DatePicker("Soir", selection: $evening, displayedComponents: .hourAndMinute)
                .onChange(of: evening) { _, _ in commitSchedule() }
        } header: {
            Text("Heures des découvertes")
        } footer: {
            Text("Les trois heures doivent rester dans cet ordre. Une heure qui passerait avant la précédente est décalée automatiquement, sans quoi le mot du soir ne couvrirait plus la nuit.")
        }
    }

    private func commitSchedule() {
        guard didLoadSchedule else { return }
        environment.updateSchedule(
            SlotSchedule(
                morning: time(from: morning),
                afternoon: time(from: afternoon),
                evening: time(from: evening)
            )
        )
    }

    // MARK: - Fuseau

    private var timeZoneSection: some View {
        Section {
            Picker("Fuseau", selection: timeZoneBinding) {
                Text("Heure de Paris").tag(TimeZoneChoice.paris)
                Text("Fuseau de l'appareil").tag(TimeZoneChoice.device)
            }
        } header: {
            Text("Fuseau horaire")
        } footer: {
            Text("« Heure de Paris » garde les mêmes heures où que vous soyez. « Fuseau de l'appareil » décale les découvertes quand vous voyagez.")
        }
    }

    private enum TimeZoneChoice: Hashable {
        case paris
        case device
    }

    private var timeZoneBinding: Binding<TimeZoneChoice> {
        Binding(
            get: {
                switch environment.settings.timeZonePolicy {
                case .device: return .device
                case .fixed: return .paris
                }
            },
            set: { choice in
                switch choice {
                case .paris: environment.updateTimeZonePolicy(.fixed(identifier: "Europe/Paris"))
                case .device: environment.updateTimeZonePolicy(.device)
                }
            }
        )
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            Toggle(
                "Me prévenir à chaque découverte",
                isOn: Binding(
                    get: { environment.settings.notificationsEnabled },
                    set: { environment.setNotificationsEnabled($0) }
                )
            )
        } header: {
            Text("Notifications")
        } footer: {
            Text(notificationFooter)
        }
    }

    private var notificationFooter: String {
        switch environment.notificationStatus {
        case .denied:
            return "Les notifications sont refusées dans les réglages d'iOS. Autorisez-les pour Vocabulle dans Réglages › Notifications."
        case .authorized, .provisional, .ephemeral:
            return "Le rappel annonce qu'une découverte vous attend, sans révéler le mot."
        default:
            return "Désactivées par défaut. Vocabulle ne demande l'autorisation que si vous activez cet interrupteur, et n'envoie jamais de notification publicitaire."
        }
    }

    // MARK: - Corpus

    private var corpusSection: some View {
        Section {
            if let metadata = environment.metadata {
                LabeledContent("Termes", value: "\(metadata.entryCount)")
                ForEach(EntryCategory.allCases, id: \.self) { category in
                    LabeledContent(category.displayName, value: "\(metadata.count(for: category))")
                }
                LabeledContent("Source", value: metadata.sourceProject)
                LabeledContent("Licence", value: metadata.licenseName)
                LabeledContent(
                    "Produit le",
                    value: FrenchFormat.calendarDay(metadata.generatedAt, timeZone: .gmt)
                )
                LabeledContent("Version de schéma", value: "\(metadata.schemaVersion)")
            } else {
                Text("Métadonnées du corpus indisponibles.")
                    .font(.footnote)
                    .foregroundStyle(VocabulleTheme.caution)
            }
        } header: {
            Text("Corpus embarqué")
        } footer: {
            Text("Le corpus est embarqué dans l'application : aucune connexion n'est nécessaire, et rien de votre usage ne quitte l'appareil.")
        }
    }

    // MARK: - Partage avec le widget

    private var sharingSection: some View {
        Section {
            LabeledContent("État", value: environment.containerTier.displayName)
            if !environment.attemptedGroupIdentifiers.isEmpty {
                LabeledContent(
                    "Groupes essayés",
                    value: environment.attemptedGroupIdentifiers.joined(separator: ", ")
                )
            }
        } header: {
            Text("Partage avec le widget")
        } footer: {
            Text(sharingFooter)
        }
    }

    private var sharingFooter: String {
        if environment.isSharedWithWidget {
            return "L'application et le widget partagent le même fichier d'état. « Autre mot » et « Déjà connu » agissent donc aussi depuis l'écran verrouillé."
        }
        return "Le profil d'installation ne fournit pas de conteneur partagé : c'est le cas courant avec un compte Apple gratuit. Le widget affiche le terme prévu pour le créneau, mais ne peut pas enregistrer vos actions. Vocabulle ne contourne jamais cette limite par un second stockage privé, qui ferait diverger l'écran verrouillé et l'application."
    }

    // MARK: - Usage

    private var usageSection: some View {
        Section {
            LabeledContent("Termes marqués connus", value: "\(environment.state.knownEntryIDs.count)")
            LabeledContent("Favoris", value: "\(environment.state.favouriteEntryIDs.count)")
            LabeledContent("Fiches consultées", value: "\(environment.state.consultedEntryIDs.count)")
            LabeledContent("Tours complets", value: "\(environment.state.roundCount)")
        } header: {
            Text("Votre usage")
        } footer: {
            Text("Ces données restent dans le conteneur local de l'application. Aucun compte, aucun serveur, aucune analyse.")
        }
    }

    // MARK: - Conversions

    private func date(from time: TimeOfDay) -> Date {
        var components = DateComponents()
        components.hour = time.hour
        components.minute = time.minute
        return Calendar.vocabulle.date(from: components) ?? Date()
    }

    private func time(from date: Date) -> TimeOfDay {
        let components = Calendar.vocabulle.dateComponents([.hour, .minute], from: date)
        return TimeOfDay(hour: components.hour ?? 8, minute: components.minute ?? 0)
    }
}
