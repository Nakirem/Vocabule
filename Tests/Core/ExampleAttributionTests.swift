import XCTest
@testable import VocabulleCore

/// La règle d'attribution des exemples, et la raison pour laquelle elle est
/// écrite ainsi.
///
/// Le Wiktionnaire cite très souvent un ouvrage sans nommer d'auteur :
/// « Zeste de Savoir », « Journal du siège d'Andrinople ». Exiger un nom de
/// personne ferait tomber 225 exemples parfaitement sourcés — et surtout, cela
/// contredirait la règle qu'applique `scripts/validate_corpus.py`, qui accepte
/// un exemple dès qu'il nomme un auteur **ou** un ouvrage. Rendre les deux
/// règles identiques est tout l'objet de ce fichier.
///
/// Ce qui reste proscrit, et que ces tests protègent, c'est l'exemple qui
/// n'avance aucune provenance : celui-là serait une citation inventée.
///
/// Le contrôle de bout en bout sur les 1 432 fiches réelles est fait par
/// `SQLiteCorpusStoreTests.testEveryEntryDecodesAndValidates`.
final class ExampleAttributionTests: XCTestCase {

    // MARK: - Vérifiabilité

    func testAnExampleCreditedToAnAuthorIsVerifiable() {
        let example = Example(
            text: "Un exemple d'emploi.",
            origin: .wiktionary,
            attributedTo: "Madeleine Chapsal",
            sourceTitle: "Trous de mémoire"
        )

        XCTAssertFalse(example.hasUnverifiableAttribution)
    }

    /// Le cas qui a fait échouer la validation sur 201 fiches.
    func testAnExampleCreditedOnlyToAWorkIsVerifiable() {
        let example = Example(
            text: "Un exemple d'emploi.",
            origin: .wiktionary,
            attributedTo: nil,
            sourceTitle: "Zeste de Savoir"
        )

        XCTAssertFalse(
            example.hasUnverifiableAttribution,
            "Un ouvrage nommé est une provenance : exiger un nom d'auteur écarterait 225 exemples sourcés"
        )
    }

    /// Le seul cas réellement fautif : aucune provenance, donc rien à vérifier.
    func testAnExampleCreditingNeitherAuthorNorWorkIsNotVerifiable() {
        let example = Example(
            text: "Un exemple d'emploi.",
            origin: .wiktionary,
            attributedTo: nil,
            sourceTitle: nil
        )

        XCTAssertTrue(example.hasUnverifiableAttribution)
    }

    func testAnExampleWrittenForVocabulleNeedsNoExternalCredit() {
        let example = Example(text: "Un exemple d'emploi.", origin: .vocabulle)

        XCTAssertFalse(
            example.hasUnverifiableAttribution,
            "Vocabulle assume ses propres exemples : ils sont identifiés comme tels, pas attribués à autrui"
        )
    }

    /// Une chaîne vide n'est pas un nom. Sans cette précaution, une colonne
    /// remplie de blancs passerait pour une attribution.
    func testEmptyStringsCountAsAbsent() {
        let blank = Example(
            text: "Un exemple d'emploi.",
            origin: .wiktionary,
            attributedTo: "",
            sourceTitle: ""
        )

        XCTAssertTrue(blank.hasUnverifiableAttribution)
        XCTAssertNil(blank.creditName)
    }

    // MARK: - Mention affichée

    func testCreditLineNamesTheAuthorWhenThereIsOne() {
        let example = Example(
            text: "Un exemple d'emploi.",
            origin: .wiktionary,
            attributedTo: "Stendhal",
            sourceTitle: "Lucien Leuwen"
        )

        XCTAssertEqual(example.creditLine, "Exemple issu du Wiktionnaire — Stendhal")
    }

    /// L'ouvrage était stocké mais jamais affiché : la mention se réduisait à
    /// « Exemple issu du Wiktionnaire », en taisant la source réelle.
    func testCreditLineFallsBackToTheWorkTitle() {
        let example = Example(
            text: "Un exemple d'emploi.",
            origin: .wiktionary,
            attributedTo: nil,
            sourceTitle: "Zeste de Savoir"
        )

        XCTAssertEqual(example.creditLine, "Exemple issu du Wiktionnaire — Zeste de Savoir")
    }

    func testCreditLineForAVocabulleExampleNamesVocabulle() {
        let example = Example(text: "Un exemple d'emploi.", origin: .vocabulle)

        XCTAssertEqual(example.creditLine, "Exemple rédigé pour Vocabulle")
    }

    /// La mention ne doit jamais être vide dès lors qu'une provenance existe :
    /// un exemple affiché sans source est exactement ce que le projet interdit.
    func testCreditLineIsNeverEmptyWhenAProvenanceExists() {
        for origin in ExampleOrigin.allCases {
            let example = Example(
                text: "Un exemple d'emploi.",
                origin: origin,
                attributedTo: nil,
                sourceTitle: "Un ouvrage"
            )

            XCTAssertFalse(
                example.creditLine.isEmpty,
                "Provenance « \(origin.rawValue) » : mention vide alors que l'ouvrage est nommé"
            )
        }
    }
}
