"""Contrôles sur le corpus embarqué. Portables, sans Xcode.

# Ce que ce script attrape, et que rien d'autre n'attraperait

Un corpus peut être produit, peser trois mégaoctets, contenir mille fiches — et
être **indécodable** par l'application. Le cas s'est produit pendant le
développement : les colonnes JSON contenaient ``target_term`` là où
`JSONDecoder` attendait ``targetTerm``. Rien ne l'aurait signalé : la chaîne de
production aurait réussi, la base aurait été valide, et l'application aurait
affiché « corpus inaccessible » en accusant le mauvais coupable.

Ce script vérifie donc trois familles de choses :

1. **Le contrat avec Swift.** Les clés JSON et les valeurs d'énumération doivent
   correspondre exactement aux noms déclarés côté Swift. Une clé en trop, une
   clé manquante, une valeur inconnue — tout est signalé avec le nom de la fiche.
2. **La cohérence interne.** Chaque terme associé pointe vers une fiche qui
   existe : un lien mort dans l'interface serait pire qu'une absence de lien.
3. **Les invariants éditoriaux** que le modèle Swift impose déjà, vérifiés ici
   une seconde fois — c'est la base livrée qu'on contrôle, pas la chaîne.

Il vérifie aussi que la normalisation Python correspond au fichier de référence
partagé avec les tests Swift. Une divergence entre les deux implémentations ne
casserait pas la compilation : elle rendrait seulement la recherche muette.
"""
from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from tools.corpus import normalize as norm  # noqa: E402
from tools.corpus.build import SCHEMA_VERSION  # noqa: E402

DATABASE = ROOT / "Resources" / "vocabulle-corpus.sqlite"
FIXTURE = ROOT / "Tests" / "Fixtures" / "normalization.json"

#: Nombre minimal de fiches vérifiées exigé par le cahier des charges.
MINIMUM_ENTRIES = 300

#: Plafond de taille du corpus initial, en octets.
MAX_DATABASE_BYTES = 100 * 1024 * 1024

#: Longueur maximale de la définition courte, alignée sur `LexicalEntry`.
SHORT_DEFINITION_MAX_LENGTH = 120

#: Clés JSON attendues par les modèles Swift. Écrites ici en dur, à dessein :
#: c'est la seule copie indépendante du contrat. Les lire depuis le code de
#: production rendrait le contrôle circulaire.
EXPECTED_KEYS: dict[str, set[str]] = {
    "examples": {"text", "origin", "attributedTo", "sourceTitle"},
    "relations": {"targetID", "targetTerm", "type", "evidence", "rationale"},
    "sources": {"kind", "title", "url", "revisionID", "fetchedAt", "license"},
}

#: Valeurs autorisées, alignées sur les énumérations Swift.
ALLOWED_VALUES: dict[str, set[str]] = {
    "kind": {"word", "technicalTerm", "expression"},
    "category": {"literary", "expression", "conversation", "specialized"},
    "grammar_part": {
        "nomCommun", "nomPropre", "adjectif", "verbe", "adverbe",
        "locutionNominale", "locutionVerbale", "locutionAdjectivale",
        "locutionAdverbiale", "locutionInterjective", "interjection",
        "preposition", "conjonction", "pronom", "determinant",
    },
    "grammar_gender": {"masculin", "feminin", "masculinOuFeminin", "invariable"},
    "registers": {
        "courant", "soutenu", "litteraire", "familier", "argotique", "populaire",
        "vieilli", "desuet", "rare", "technique", "pejorative", "meliorative",
        "humoristique", "ironique", "figure", "parExtension", "regionalisme",
    },
    "provenance": {"wiktionary", "editorial", "wikipedia"},
    "example_origin": {"vocabulle", "wiktionary", "wikipedia"},
    "relation_type": {
        "synonym", "antonym", "sameOrigin", "sameSchool", "sameEra",
        "contrast", "sameContext",
    },
    "relation_evidence": {"attested", "editorial"},
    "source_kind": {"wiktionary", "wikipedia", "book", "web"},
    "license": {
        "CC BY-SA 4.0", "CC BY-SA 3.0", "CC BY-SA 2.5", "CC BY-SA",
        "domaine public", "rédaction Vocabulle",
    },
}

failures: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def check_keys(payload: dict, family: str, where: str) -> bool:
    """Les clés JSON correspondent-elles au modèle Swift ?"""
    expected = EXPECTED_KEYS[family]
    actual = set(payload)
    if actual == expected:
        return True
    missing = expected - actual
    unexpected = actual - expected
    details = []
    if missing:
        details.append(f"manquantes {sorted(missing)}")
    if unexpected:
        details.append(f"inattendues {sorted(unexpected)}")
    failures.append(f"{where} : clés {family} incorrectes ({' ; '.join(details)})")
    return False


def check_values(values: list[str], family: str, where: str) -> None:
    allowed = ALLOWED_VALUES[family]
    unknown = [value for value in values if value not in allowed]
    check(
        not unknown,
        f"{where} : valeur(s) {family} inconnue(s) {unknown} — le décodage Swift échouerait",
    )


def check_normalization_fixture() -> None:
    """La normalisation Python correspond-elle au contrat partagé ?"""
    if not FIXTURE.is_file():
        failures.append(f"Fichier de référence absent : {FIXTURE.relative_to(ROOT)}")
        return
    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
    for case in fixture["normalize"]:
        actual = norm.normalize(case["input"])
        check(
            actual == case["expected"],
            f"normalize({case['input']!r}) = {actual!r}, attendu {case['expected']!r} "
            "— la recherche ne trouvera plus le terme",
        )
    for case in fixture["slug"]:
        actual = norm.slug(case["input"])
        check(
            actual == case["expected"],
            f"slug({case['input']!r}) = {actual!r}, attendu {case['expected']!r} "
            "— l'identifiant de fiche change",
        )


def report_distribution(counts: dict[str, int], total: int, rows: list) -> None:
    """Affiche la répartition, et signale les catégories trop maigres.

    Le moteur de sélection distribue 8 littéraires, 5 expressions, 4 termes de
    conversation et 3 spécialisés par cycle de vingt créneaux. Une catégorie qui
    ne contient pas au moins deux fois son quota épuiserait le corpus en quelques
    jours d'usage — c'est une information de conception, pas une erreur.
    """
    quotas = {"literary": 8, "expression": 5, "conversation": 4, "specialized": 3}
    print(f"Fiches vérifiées : {total}")
    print()
    print("| Catégorie | Fiches | Part | Quota par cycle | Cycles couverts |")
    print("| --- | --- | --- | --- | --- |")
    for category in ("literary", "expression", "conversation", "specialized"):
        count = counts.get(category, 0)
        share = count * 100 / total if total else 0
        cycles = count // quotas[category] if quotas[category] else 0
        print(f"| {category} | {count} | {share:.1f} % | {quotas[category]} | {cycles} |")
        check(
            count >= quotas[category] * 2,
            f"Catégorie {category} trop maigre : {count} fiches pour un quota de "
            f"{quotas[category]} par cycle — le corpus s'épuiserait en moins de deux cycles",
        )

    with_examples = sum(1 for row in rows if json.loads(row["examples"]))
    with_etymology = sum(1 for row in rows if row["etymology"])
    with_history = sum(1 for row in rows if row["history"])
    print()
    print(f"Fiches avec étymologie : {with_etymology} ({with_etymology * 100 // total} %)")
    print(f"Fiches avec exemple : {with_examples} ({with_examples * 100 // total} %)")
    print(
        f"Fiches avec section « histoire » : {with_history} "
        "— le Wiktionnaire n'en fournit pas, et on n'en invente pas"
    )


def validate(connection: sqlite3.Connection) -> None:
    metadata = {
        row["key"]: row["value"]
        for row in connection.execute("SELECT key, value FROM metadata")
    }
    check("corpus" in metadata, "Métadonnées du corpus absentes de la table metadata")
    if "corpus" in metadata:
        corpus = json.loads(metadata["corpus"])
        for key in (
            "schemaVersion", "generatedAt", "entryCount", "countsByCategory",
            "sourceProject", "licenseName", "pipelineVersion",
        ):
            check(key in corpus, f"Métadonnée manquante : {key}")
        check(
            corpus.get("sourceProject") == "fr.wiktionary.org",
            f"Projet source inattendu : {corpus.get('sourceProject')!r}",
        )
        check(
            "CC BY-SA" in str(corpus.get("licenseName", "")),
            "La licence des contenus repris doit être mentionnée et distincte de celle du code",
        )
        check(
            int(metadata.get("schemaVersion", "0")) == SCHEMA_VERSION,
            f"Version de schéma de la base ({metadata.get('schemaVersion')}) "
            f"différente de celle du code ({SCHEMA_VERSION})",
        )

    rows = list(connection.execute("SELECT * FROM entries"))
    check(
        len(rows) >= MINIMUM_ENTRIES,
        f"Corpus insuffisant : {len(rows)} fiches vérifiées, minimum {MINIMUM_ENTRIES}",
    )

    identifiers = [row["id"] for row in rows]
    duplicates = {value for value in identifiers if identifiers.count(value) > 1}
    check(not duplicates, f"Identifiants dupliqués : {sorted(duplicates)[:5]}")
    known = set(identifiers)

    if "corpus" in metadata:
        declared = json.loads(metadata["corpus"]).get("entryCount")
        check(
            declared == len(rows),
            f"entryCount annoncé ({declared}) différent du nombre réel de fiches ({len(rows)})",
        )

    counts: dict[str, int] = {}
    for row in rows:
        where = f"fiche « {row['id']} »"
        check_values([row["kind"]], "kind", where)
        check_values([row["category"]], "category", where)
        counts[row["category"]] = counts.get(row["category"], 0) + 1
        if row["grammar_part"]:
            check_values([row["grammar_part"]], "grammar_part", where)
        if row["grammar_gender"]:
            check_values([row["grammar_gender"]], "grammar_gender", where)

        short = row["short_definition"] or ""
        check(bool(short.strip()), f"{where} : définition courte vide")
        check(
            len(short) <= SHORT_DEFINITION_MAX_LENGTH,
            f"{where} : définition courte de {len(short)} caractères, "
            f"limite {SHORT_DEFINITION_MAX_LENGTH} — le widget la tronquerait",
        )
        check(bool((row["long_definition"] or "").strip()), f"{where} : définition longue vide")

        check_values(json.loads(row["registers"]), "registers", where)
        for column in ("short_provenance", "long_provenance"):
            check_values([row[column]], "provenance", where)
        for value_column, provenance_column in (
            ("usage_note", "usage_note_provenance"),
            ("etymology", "etymology_provenance"),
            ("history", "history_provenance"),
        ):
            if row[value_column]:
                check_values([row[provenance_column]], "provenance", where)
            else:
                check(
                    row[provenance_column] is None,
                    f"{where} : {provenance_column} renseignée sans texte",
                )

        examples = json.loads(row["examples"])
        check(len(examples) <= 2, f"{where} : {len(examples)} exemples, maximum 2")
        for index, example in enumerate(examples):
            if not check_keys(example, "examples", f"{where}, exemple {index + 1}"):
                continue
            check_values([example["origin"]], "example_origin", where)
            check(
                bool((example["text"] or "").strip()),
                f"{where} : exemple {index + 1} vide",
            )
            if example["origin"] != "vocabulle":
                check(
                    bool(example["attributedTo"] or example["sourceTitle"]),
                    f"{where} : exemple {index + 1} attribué sans auteur ni source vérifiable",
                )

        relations = json.loads(row["relations"])
        check(
            2 <= len(relations) <= 4,
            f"{where} : {len(relations)} termes associés, la fourchette est 2 à 4",
        )
        for index, relation in enumerate(relations):
            if not check_keys(relation, "relations", f"{where}, relation {index + 1}"):
                continue
            check_values([relation["type"]], "relation_type", where)
            check_values([relation["evidence"]], "relation_evidence", where)
            check(
                bool(relation["rationale"].strip()),
                f"{where} : relation {index + 1} sans justification",
            )
            check(
                relation["targetID"] in known,
                f"{where} : terme associé « {relation['targetID']} » absent du corpus "
                "— l'application afficherait un lien mort",
            )
            check(
                relation["targetID"] != row["id"],
                f"{where} : fiche liée à elle-même",
            )

        sources = json.loads(row["sources"])
        check(bool(sources), f"{where} : aucune source")
        for index, source in enumerate(sources):
            if not check_keys(source, "sources", f"{where}, source {index + 1}"):
                continue
            check_values([source["kind"]], "source_kind", where)
            if source["license"]:
                check_values([source["license"]], "license", where)
            check(
                bool((source["title"] or "").strip()),
                f"{where} : source {index + 1} sans titre",
            )
        check(
            any(source.get("kind") == "wiktionary" for source in sources),
            f"{where} : provenance Wiktionnaire sans source Wiktionnaire",
        )

    if len(rows) >= MINIMUM_ENTRIES:
        report_distribution(counts, len(rows), rows)


def report() -> int:
    if failures:
        for message in failures:
            print(f"ÉCHEC : {message}")
        print(f"{len(failures)} problème(s) détecté(s) dans le corpus.")
        return 1
    print()
    print("Corpus conforme : contrat Swift, cohérence des liens, invariants éditoriaux.")
    return 0


def main() -> int:
    check_normalization_fixture()

    if not DATABASE.is_file():
        failures.append(
            f"Corpus absent : {DATABASE.relative_to(ROOT)} — lancer python3 -m tools.corpus.build"
        )
        return report()

    size = DATABASE.stat().st_size
    check(
        size <= MAX_DATABASE_BYTES,
        f"Corpus trop volumineux : {size / 1024 / 1024:.1f} Mio, plafond "
        f"{MAX_DATABASE_BYTES / 1024 / 1024:.0f} Mio",
    )

    connection = sqlite3.connect(f"file:{DATABASE}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    try:
        validate(connection)
    finally:
        connection.close()

    return report()


if __name__ == "__main__":
    sys.exit(main())
