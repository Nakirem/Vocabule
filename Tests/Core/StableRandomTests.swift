import XCTest
@testable import VocabulleCore

/// Le projet interdit explicitement d'utiliser « un hachage inter-processus
/// instable comme graine persistante » : `hashValue` de Swift change à chaque
/// lancement, ce qui donnerait un terme différent à chaque ouverture de
/// l'application et un terme différent entre l'application et son widget.
///
/// Ces tests **figent l'algorithme**. Les valeurs de référence ci-dessous sont
/// calculées à la main, pas recopiées d'une exécution : si quelqu'un modifie
/// FNV-1a, SplitMix64 ou l'ordre des opérations, la suite échoue. C'est voulu —
/// changer l'algorithme changerait rétroactivement le terme affiché chez tous
/// les utilisateurs existants.
final class StableRandomTests: XCTestCase {

    func testFnv1a64MatchesPublishedVectors() {
        // Vecteurs de test publiés de la FNV-1a 64 bits.
        XCTAssertEqual(StableHash.fnv1a64(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(StableHash.fnv1a64("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(StableHash.fnv1a64("foobar"), 0x8594_4171_f739_67e8)
    }

    func testFnv1a64IsStableForFrenchTermsWithAccents() {
        // Le hachage porte sur les octets UTF-8 : « é » compte pour deux octets.
        XCTAssertEqual(StableHash.fnv1a64("monomaniaque"), 0x37c2_a055_eb30_5ec1)
        XCTAssertNotEqual(StableHash.fnv1a64("ephemere"), StableHash.fnv1a64("éphémère"))
    }

    func testSplitMix64MatchesReference() {
        XCTAssertEqual(StableHash.splitMix64(0), 0xe220_a839_7b1d_cdaf)
        XCTAssertEqual(StableHash.splitMix64(1), 0x910a_2dec_8902_5cc1)
    }

    func testCombineSeparatesAdjacentParts() {
        // Sans octet séparateur, ["ab"] et ["a","b"] produiraient la même graine
        // et deux créneaux différents tomberaient sur le même terme.
        XCTAssertEqual(StableHash.combine(["ab"]), 0x270d_573f_05a8_c0e1)
        XCTAssertEqual(StableHash.combine(["a", "b"]), 0xe776_4dd9_fb80_43aa)
        XCTAssertNotEqual(StableHash.combine(["ab"]), StableHash.combine(["a", "b"]))
        XCTAssertNotEqual(StableHash.combine(["ab", "c"]), StableHash.combine(["a", "bc"]))
    }

    func testCombineDependsOnOrder() {
        XCTAssertNotEqual(StableHash.combine(["a", "b"]), StableHash.combine(["b", "a"]))
    }

    func testGeneratorProducesTheSameSequenceForTheSameSeed() {
        var first = StableRandom(seed: 42)
        var second = StableRandom(seed: 42)
        for _ in 0..<64 {
            XCTAssertEqual(first.next(), second.next())
        }
    }

    func testGeneratorSequenceIsPinned() {
        // Suite figée : elle ne doit jamais changer, sous peine de modifier le
        // terme affiché sur l'écran verrouillé des installations existantes.
        var random = StableRandom(seed: 42)
        XCTAssertEqual(random.next(), 0xbdd7_3226_2feb_6e95)
        XCTAssertEqual(random.next(), 0x28ef_e333_b266_f103)
        XCTAssertEqual(random.next(), 0x4752_6757_130f_9f52)
    }

    func testDifferentSeedsProduceDifferentSequences() {
        var first = StableRandom(seedParts: ["graine-a"])
        var second = StableRandom(seedParts: ["graine-b"])
        let firstDraws = (0..<8).map { _ in first.next() }
        let secondDraws = (0..<8).map { _ in second.next() }
        XCTAssertNotEqual(firstDraws, secondDraws)
    }

    func testSlotSeedIsPinnedToItsComponents() {
        // Graine d'un créneau, telle que le moteur la construit. La figer
        // garantit que l'application et l'extension calculent la même chose.
        let seed = StableHash.combine(["vocabulle-test", "2026-10-12#morning", "literary", "0"])
        XCTAssertEqual(seed, 16695235773703921653)
        var random = StableRandom(seed: seed)
        XCTAssertEqual(random.next(), 0x8443_c5bb_77ef_aca4)
        XCTAssertEqual(random.next(), 0x63c3_e285_2c62_c053)
    }

    func testNextIntStaysWithinBound() {
        var random = StableRandom(seedParts: ["bornes"])
        for bound in [1, 2, 3, 7, 100] {
            for _ in 0..<200 {
                let value = random.nextInt(upperBound: bound)
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThan(value, bound)
            }
        }
    }

    func testNextIntHandlesDegenerateBounds() {
        var random = StableRandom(seedParts: ["borne-nulle"])
        XCTAssertEqual(random.nextInt(upperBound: 0), 0)
        XCTAssertEqual(random.nextInt(upperBound: -5), 0)
    }

    func testNextIntIsUniformEnough() {
        // Le rejet du biais de repliement doit donner une répartition
        // sensiblement égale. On ne teste pas la qualité statistique du
        // générateur — ce n'est pas son rôle — mais l'absence de biais grossier.
        var random = StableRandom(seedParts: ["uniformite"])
        let bound = 4
        let draws = 4000
        var counts = [Int](repeating: 0, count: bound)
        for _ in 0..<draws {
            counts[random.nextInt(upperBound: bound)] += 1
        }
        let expected = draws / bound
        for count in counts {
            XCTAssertGreaterThan(count, expected / 2, "Répartition trop déséquilibrée : \(counts)")
            XCTAssertLessThan(count, expected * 2, "Répartition trop déséquilibrée : \(counts)")
        }
    }

    func testNextIntIsReproducible() {
        var first = StableRandom(seedParts: ["reprise"])
        var second = StableRandom(seedParts: ["reprise"])
        for _ in 0..<50 {
            XCTAssertEqual(first.nextInt(upperBound: 37), second.nextInt(upperBound: 37))
        }
    }
}
