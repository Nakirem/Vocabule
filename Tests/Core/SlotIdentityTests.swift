import XCTest
@testable import VocabulleCore

/// Identité d'un créneau : c'est la clé de tout le reste. Le terme affiché est
/// une fonction de cette identité, donc une identité qui varie dans le temps
/// ferait varier le terme.
final class SlotIdentityTests: XCTestCase {

    func testDescriptionRoundTrips() {
        for period in DayPeriod.allCases {
            let slot = SlotID(day: LocalDay(year: 2026, month: 10, day: 12), period: period)
            let parsed = SlotID(parsing: slot.description)
            XCTAssertEqual(parsed, slot, "Aller-retour cassé pour \(slot.description)")
        }
    }

    func testDescriptionHasAStableShape() {
        let slot = SlotID(day: LocalDay(year: 2026, month: 10, day: 12), period: .evening)
        XCTAssertEqual(slot.description, "2026-10-12#evening")
    }

    func testParsingRejectsMalformedText() {
        // Une clé d'état illisible doit être ignorée, jamais interprétée de
        // travers : c'est ce qui protège le registre des créneaux.
        XCTAssertNil(SlotID(parsing: ""))
        XCTAssertNil(SlotID(parsing: "2026-10-12"))
        XCTAssertNil(SlotID(parsing: "2026-10-12#nuit"))
        XCTAssertNil(SlotID(parsing: "2026-10#morning"))
        XCTAssertNil(SlotID(parsing: "2026-10-12#morning#extra"))
        XCTAssertNil(SlotID(parsing: "vingt-vingt#morning"))
    }

    func testOrderingIsChronological() {
        let morning = SlotID(day: LocalDay(year: 2026, month: 10, day: 12), period: .morning)
        let afternoon = SlotID(day: LocalDay(year: 2026, month: 10, day: 12), period: .afternoon)
        let evening = SlotID(day: LocalDay(year: 2026, month: 10, day: 12), period: .evening)
        let nextMorning = SlotID(day: LocalDay(year: 2026, month: 10, day: 13), period: .morning)

        XCTAssertLessThan(morning, afternoon)
        XCTAssertLessThan(afternoon, evening)
        XCTAssertLessThan(evening, nextMorning)
    }

    func testPeriodOrderMatchesChronology() {
        XCTAssertEqual(DayPeriod.morning.order, 0)
        XCTAssertEqual(DayPeriod.afternoon.order, 1)
        XCTAssertEqual(DayPeriod.evening.order, 2)
        XCTAssertEqual(DayPeriod.allCases.count, 3)
    }

    func testTimeOfDayParsesAndRejects() {
        let parsed = TimeOfDay(parse: "08:05")
        XCTAssertEqual(parsed?.hour, 8)
        XCTAssertEqual(parsed?.minute, 5)
        XCTAssertNil(TimeOfDay(parse: ""))
        XCTAssertNil(TimeOfDay(parse: "8h"))
        XCTAssertNil(TimeOfDay(parse: "25:00"))
        XCTAssertNil(TimeOfDay(parse: "08:75"))
    }

    func testTimeOfDayRejectsOutOfRangeValues() {
        XCTAssertNil(TimeOfDay(parse: "24:00"))
        XCTAssertNil(TimeOfDay(parse: "-1:00"))
    }

    func testLocalDayArithmeticCrossesMonthAndYearBoundaries() {
        let endOfYear = LocalDay(year: 2026, month: 12, day: 31)
        XCTAssertEqual(endOfYear.adding(days: 1), LocalDay(year: 2027, month: 1, day: 1))
        XCTAssertEqual(LocalDay(year: 2026, month: 3, day: 1).adding(days: -1), LocalDay(year: 2026, month: 2, day: 28))
        XCTAssertEqual(LocalDay(year: 2026, month: 1, day: 1).previous(), LocalDay(year: 2025, month: 12, day: 31))
    }

    func testLeapDayIsHandled() {
        // 2028 est bissextile ; 2026 ne l'est pas.
        XCTAssertEqual(LocalDay(year: 2028, month: 2, day: 28).adding(days: 1), LocalDay(year: 2028, month: 2, day: 29))
        XCTAssertEqual(LocalDay(year: 2026, month: 2, day: 28).adding(days: 1), LocalDay(year: 2026, month: 3, day: 1))
    }
}
