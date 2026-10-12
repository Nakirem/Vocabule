import XCTest
@testable import VocabulleCore

/// Le cœur temporel du projet. Une erreur ici et c'est le terme du soir qui
/// disparaît à minuit, ou deux créneaux qui pointent vers la même fiche.
///
/// Toutes les dates de ces tests sont exprimées explicitement, soit en heure de
/// Paris (`ParisTime`), soit en UTC (`UTCTime`). Aucune ne dépend de l'horloge
/// ni du fuseau de la machine qui exécute la suite.
final class SlotResolverTests: XCTestCase {

    private static let paris = TimeZone(identifier: "Europe/Paris")!
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private static let utc = TimeZone(identifier: "UTC")!

    private func resolver(
        schedule: SlotSchedule = .default,
        policy: TimeZonePolicy = .fixed(identifier: "Europe/Paris")
    ) -> SlotResolver {
        SlotResolver(schedule: schedule, timeZonePolicy: policy, deviceTimeZone: Self.utc)
    }

    private func slot(_ year: Int, _ month: Int, _ day: Int, _ period: DayPeriod) -> SlotID {
        SlotID(day: LocalDay(year: year, month: month, day: day), period: period)
    }

    // MARK: - Grille horaire

    func testDefaultScheduleMatchesTheDocumentedTimes() {
        let schedule = SlotSchedule.default
        XCTAssertEqual(schedule.morning, TimeOfDay(hour: 8))
        XCTAssertEqual(schedule.afternoon, TimeOfDay(hour: 14))
        XCTAssertEqual(schedule.evening, TimeOfDay(hour: 20))
        XCTAssertEqual(schedule.orderedTimes, [TimeOfDay(hour: 8), TimeOfDay(hour: 14), TimeOfDay(hour: 20)])
        XCTAssertTrue(schedule.isStrictlyIncreasing)
        XCTAssertTrue(schedule.validationIssues().isEmpty)
    }

    func testNormalizationPushesAfternoonPastMorning() {
        let broken = SlotSchedule(
            morning: TimeOfDay(hour: 10),
            afternoon: TimeOfDay(hour: 9),
            evening: TimeOfDay(hour: 20)
        )
        XCTAssertFalse(broken.isStrictlyIncreasing)
        XCTAssertEqual(broken.validationIssues(), [.notStrictlyIncreasing])

        let fixed = broken.normalized()
        XCTAssertEqual(fixed.afternoon, TimeOfDay(hour: 10, minute: 1))
        XCTAssertEqual(fixed.evening, TimeOfDay(hour: 20))
        XCTAssertTrue(fixed.isStrictlyIncreasing)
    }

    func testNormalizationPushesEveningPastAfternoon() {
        let overlapping = SlotSchedule(
            morning: TimeOfDay(hour: 8),
            afternoon: TimeOfDay(hour: 20),
            evening: TimeOfDay(hour: 9)
        )
        let fixed = overlapping.normalized()
        XCTAssertEqual(fixed.morning, TimeOfDay(hour: 8))
        XCTAssertEqual(fixed.afternoon, TimeOfDay(hour: 20))
        XCTAssertEqual(fixed.evening, TimeOfDay(hour: 20, minute: 1))
        XCTAssertTrue(fixed.isStrictlyIncreasing)
    }

    func testNormalizationFallsBackToDefaultWhenNoOrderIsPossible() {
        // Trois créneaux collés en fin de journée : aucun décalage ne peut
        // produire une grille croissante. On préfère la grille par défaut à une
        // journée sans créneau valide.
        let impossible = SlotSchedule(
            morning: TimeOfDay(hour: 23, minute: 58),
            afternoon: TimeOfDay(hour: 23, minute: 58),
            evening: TimeOfDay(hour: 23, minute: 58)
        )
        XCTAssertEqual(impossible.normalized(), .default)
    }

    // MARK: - Placement dans le temps

    func testStartDateUsesTheSelectedTimeZone() {
        // 08:00 à Paris le 12 octobre 2026 : heure d'été, UTC+2.
        let start = resolver().startDate(of: slot(2026, 10, 12, .morning))
        XCTAssertEqual(start, UTCTime.instant(2026, 10, 12, 6, 0))
    }

    func testWinterOffsetIsUsedOutsideSummerTime() {
        // 08:00 à Paris le 15 décembre 2026 : heure d'hiver, UTC+1.
        let start = resolver().startDate(of: slot(2026, 12, 15, .morning))
        XCTAssertEqual(start, UTCTime.instant(2026, 12, 15, 7, 0))
    }

    func testEndDateIsTheStartOfTheNextSlot() {
        let paris = resolver()
        let evening = slot(2026, 10, 12, .evening)
        XCTAssertEqual(paris.endDate(of: evening), paris.startDate(of: slot(2026, 10, 13, .morning)))
    }

    func testCurrentSlotIsTheLastOneStarted() {
        let paris = resolver()
        XCTAssertEqual(paris.currentSlot(at: ParisTime.instant(2026, 10, 12, 7, 59)), slot(2026, 10, 11, .evening))
        XCTAssertEqual(paris.currentSlot(at: ParisTime.instant(2026, 10, 12, 8, 0)), slot(2026, 10, 12, .morning))
        XCTAssertEqual(paris.currentSlot(at: ParisTime.instant(2026, 10, 12, 13, 59)), slot(2026, 10, 12, .morning))
        XCTAssertEqual(paris.currentSlot(at: ParisTime.instant(2026, 10, 12, 14, 0)), slot(2026, 10, 12, .afternoon))
        XCTAssertEqual(paris.currentSlot(at: ParisTime.instant(2026, 10, 12, 20, 0)), slot(2026, 10, 12, .evening))
    }

    func testEveningSlotSurvivesMidnight() {
        // Exigence explicite : le mot du soir reste affiché après minuit,
        // jusqu'au créneau du matin suivant.
        let paris = resolver()
        XCTAssertEqual(paris.currentSlot(at: ParisTime.instant(2026, 10, 13, 0, 1)), slot(2026, 10, 12, .evening))
        XCTAssertEqual(paris.currentSlot(at: ParisTime.instant(2026, 10, 13, 3, 0)), slot(2026, 10, 12, .evening))
        XCTAssertEqual(paris.currentSlot(at: ParisTime.instant(2026, 10, 13, 7, 59)), slot(2026, 10, 12, .evening))
        XCTAssertEqual(paris.currentSlot(at: ParisTime.instant(2026, 10, 13, 8, 0)), slot(2026, 10, 13, .morning))
    }

    // MARK: - Fuseau

    func testDevicePolicyFollowsTheDeviceZone() {
        // Le même instant : matin à Tokyo, encore la soirée de la veille à Paris.
        let instant = UTCTime.instant(2026, 10, 11, 23, 30)

        let tokyo = SlotResolver(
            schedule: .default,
            timeZonePolicy: .device,
            deviceTimeZone: Self.tokyo
        )
        XCTAssertEqual(tokyo.currentSlot(at: instant), slot(2026, 10, 12, .morning))

        let paris = SlotResolver(
            schedule: .default,
            timeZonePolicy: .device,
            deviceTimeZone: Self.paris
        )
        XCTAssertEqual(paris.currentSlot(at: instant), slot(2026, 10, 11, .evening))
    }

    func testUnknownFixedZoneFallsBackToTheDeviceZone() {
        // Une base de fuseaux incomplète ne doit pas empêcher l'application de
        // fonctionner : on retombe sur le fuseau de l'appareil.
        let policy = TimeZonePolicy.fixed(identifier: "Zones/Inconnue")
        XCTAssertEqual(policy.resolvedTimeZone(deviceTimeZone: Self.tokyo), Self.tokyo)
        XCTAssertEqual(TimeZonePolicy.device.resolvedTimeZone(deviceTimeZone: Self.tokyo), Self.tokyo)
        XCTAssertEqual(TimeZonePolicy.default.resolvedTimeZone(deviceTimeZone: Self.tokyo), Self.paris)
    }

    // MARK: - Changements d'heure

    func testSpringForwardKeepsSlotsOrderedAcrossTheMissingHour() {
        // Le 28 mars 2027 à Paris, 02:00 devient 03:00 : l'heure 02:30 n'existe
        // pas. Un créneau placé là doit tout de même obtenir un instant, et les
        // trois créneaux de la journée doivent rester strictement ordonnés.
        let schedule = SlotSchedule(
            morning: TimeOfDay(hour: 2, minute: 30),
            afternoon: TimeOfDay(hour: 14),
            evening: TimeOfDay(hour: 20)
        )
        let paris = resolver(schedule: schedule)
        let morning = slot(2027, 3, 28, .morning)

        guard let start = paris.startDate(of: morning) else {
            return XCTFail("Aucun instant pour un créneau tombant dans l'heure supprimée")
        }

        // La transition a lieu à 01:00 UTC. Selon la politique d'ajustement
        // retenue par Foundation, l'instant obtenu est 03:30 locales (01:30 UTC,
        // petits composants préservés) ou 03:00 locales (01:00 UTC). Les deux
        // sont acceptables ; ce qui ne le serait pas, c'est de glisser au
        // lendemain ou de renvoyer une heure avant la transition.
        XCTAssertGreaterThanOrEqual(start, UTCTime.instant(2027, 3, 28, 1, 0))
        XCTAssertLessThanOrEqual(start, UTCTime.instant(2027, 3, 28, 1, 30))

        let afternoon = paris.startDate(of: slot(2027, 3, 28, .afternoon))!
        let evening = paris.startDate(of: slot(2027, 3, 28, .evening))!
        XCTAssertLessThan(start, afternoon)
        XCTAssertLessThan(afternoon, evening)
    }

    func testFallBackPicksTheFirstOccurrenceOfARepeatedHour() {
        // Le 31 octobre 2027 à Paris, 03:00 redevient 02:00 : l'heure 02:30
        // existe deux fois. On retient la première, celle qui suit
        // immédiatement le créneau précédent.
        let schedule = SlotSchedule(
            morning: TimeOfDay(hour: 2, minute: 30),
            afternoon: TimeOfDay(hour: 14),
            evening: TimeOfDay(hour: 20)
        )
        let paris = resolver(schedule: schedule)
        let start = paris.startDate(of: slot(2027, 10, 31, .morning))

        XCTAssertEqual(start, UTCTime.instant(2027, 10, 31, 0, 30))
        XCTAssertNotEqual(start, UTCTime.instant(2027, 10, 31, 1, 30), "La seconde occurrence ne doit pas être retenue")
    }

    func testDayAfterAChangeOfHourIsUnaffected() {
        let paris = resolver()
        // Le lendemain de la transition d'octobre, l'offset est déjà UTC+1.
        XCTAssertEqual(
            paris.startDate(of: slot(2027, 11, 1, .morning)),
            UTCTime.instant(2027, 11, 1, 7, 0)
        )
    }

    // MARK: - Chronologie du widget

    func testUpcomingStartDatesAreStrictlyInTheFuture() {
        // Au cœur de la nuit, le créneau courant est encore celui du soir de la
        // veille : sa date de début appartient au passé et ne doit donc pas
        // figurer dans la chronologie à venir.
        let paris = resolver()
        let now = ParisTime.instant(2026, 10, 13, 3, 0)
        let upcoming = paris.upcomingStartDates(after: now, count: 3)

        XCTAssertEqual(upcoming, [
            UTCTime.instant(2026, 10, 13, 7, 0),
            UTCTime.instant(2026, 10, 13, 13, 0),
            UTCTime.instant(2026, 10, 13, 19, 0)
        ])
        for date in upcoming {
            XCTAssertGreaterThan(date, now)
        }
    }

    func testUpcomingStartDatesWithNoCountReturnsNothing() {
        XCTAssertTrue(resolver().upcomingStartDates(after: ParisTime.instant(2026, 10, 12, 9, 0), count: 0).isEmpty)
        XCTAssertTrue(resolver().upcomingStartDates(after: ParisTime.instant(2026, 10, 12, 9, 0), count: -3).isEmpty)
    }

    func testRecentSlotsWalkBackwardsThroughTheDay() {
        let paris = resolver()
        let recent = paris.recentSlots(endingAt: ParisTime.instant(2026, 10, 13, 3, 0), count: 3)
        XCTAssertEqual(recent, [
            slot(2026, 10, 12, .morning),
            slot(2026, 10, 12, .afternoon),
            slot(2026, 10, 12, .evening)
        ])
    }

    func testNominalDurationWrapsAroundMidnightForTheEveningSlot() {
        let paris = resolver()
        XCTAssertEqual(paris.nominalDuration(of: .morning), 6 * 3600)
        XCTAssertEqual(paris.nominalDuration(of: .afternoon), 6 * 3600)
        // Du soir au matin suivant : 12 heures, en traversant minuit.
        XCTAssertEqual(paris.nominalDuration(of: .evening), 12 * 3600)
    }

    // MARK: - Horloge injectable

    func testFixedClockParsesIso8601() {
        let clock = FixedClock(iso8601: "2026-10-12T07:30:00Z")
        XCTAssertEqual(clock?.now, UTCTime.instant(2026, 10, 12, 7, 30))
        XCTAssertNil(FixedClock(iso8601: "12 octobre 2026"))
    }

    func testFixedClockKeepsItsInstant() {
        let instant = UTCTime.instant(2026, 10, 12, 7, 30)
        let clock = FixedClock(instant)
        XCTAssertEqual(clock.now, instant)
        XCTAssertEqual(clock.now, instant)
    }
}
