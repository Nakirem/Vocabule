"""Orchestration de la chaîne : candidats → pages → fiches → SQLite → rapport.

Exécution :

    python3 -m tools.corpus.build --out Resources/vocabulle-corpus.sqlite

Le module est **reproductible** : mêmes entrées, mêmes sorties. Les clés du JSON
sont triées, l'ordre des fiches est celui des identifiants, et le seul horodatage
présent dans les données est la date de récupération des sources.

# Ce que le rapport contient, et pourquoi

Le cahier des charges demande un rapport de validation : doublons, données
incomplètes, sources manquantes, longueur des définitions courtes, répartition
des catégories et taille finale. On y ajoute la liste des étiquettes de modèle
non reconnues : c'est le seul moyen de savoir qu'une page a été mal lue, plutôt
que de le supposer.
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from dataclasses import asdict
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from tools.corpus import normalize as norm
    from tools.corpus import relations as relations_module
    from tools.corpus.extract import ExtractionStats, extract_entry, now_iso8601
    from tools.corpus.http import MediaWikiClient, MediaWikiError
    from tools.corpus.model import SHORT_DEFINITION_MAX_LENGTH, Entry, Rejection
else:
    from . import normalize as norm
    from . import relations as relations_module
    from .extract import ExtractionStats, extract_entry, now_iso8601
    from .http import MediaWikiClient, MediaWikiError
    from .model import SHORT_DEFINITION_MAX_LENGTH, Entry, Rejection

ROOT = Path(__file__).resolve().parents[2]

#: Version du schéma de base de données. Doit rester alignée sur
#: `SQLiteCorpusStore.supportedSchemaVersion`.
SCHEMA_VERSION = 1

#: Version de la chaîne de production, publiée dans les métadonnées du corpus.
PIPELINE_VERSION = "1.0"

#: Plafond par défaut du cache de réponses de l'API, en mégaoctets.
DEFAULT_CACHE_BUDGET_MB = 200

#: Nombre de passes de filtrage des relations.
#:
#: Écarter une fiche peut priver une autre d'une relation et la faire tomber
#: sous le minimum de deux. On répète donc jusqu'à stabilisation, avec une
#: borne : une chaîne qui ne converge pas doit s'arrêter et le dire.
MAX_FILTER_ROUNDS = 5


# MARK: - Candidats


def load_candidates(path: Path) -> list[dict]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    entries = payload.get("entries", [])
    if not entries:
        raise SystemExit(f"Aucun candidat dans {path}")
    return entries


def is_plausible_term(term: str) -> bool:
    """Un terme récolté ressemble-t-il à une entrée de dictionnaire ?

    Le filtre est volontairement strict. Une récolte qui accepte tout ramène
    des fragments de phrase, des formes conjuguées et des titres de section :
    le corpus doublerait de taille sans gagner une seule fiche utile.
    """
    text = term.strip()
    if not 3 <= len(text) <= 30:
        return False
    if ":" in text or text.startswith(("-", "'", "’")) or text.endswith("-"):
        return False
    if sum(1 for char in text if char.isalpha()) < 3:
        return False
    # Un nom propre n'est pas du vocabulaire à découvrir. La récolte avait
    # ramené « Hermès » (le dieu grec) depuis l'étymologie d'« hermétique », et
    # « Rubicon » (la rivière) depuis « franchir le Rubicon » : exacts tous les
    # deux, et hors sujet. Un sigle utile — CDI, SMIC — relève d'un choix
    # éditorial, donc de `candidates.json`, pas d'une règle automatique.
    if not text[0].islower():
        return False
    # Un préfixe ou un suffixe (« dé- ») est bien une page du Wiktionnaire,
    # mais ce n'est pas un mot qu'on propose comme découverte.
    return all(char.isalpha() or char in " -'’" for char in text)


def is_plausible_harvested_expression(term: str) -> bool:
    """Une locution récoltée mérite-t-elle d'entrer au corpus ?

    Seulement si la source la donne comme **synonyme ou antonyme** d'un terme
    déjà retenu, et si elle compte au plus quatre mots.

    La récolte ramenait sinon des collocations qui ne sont pas des unités
    lexicales — « environnement de développement », « agent secret », « pays en
    voie de développement ». Elles sont correctes, et elles n'ont rien à faire
    dans une découverte : personne ne les cherche dans un dictionnaire. Les
    expressions que Vocabulle propose sont choisies dans `candidates.json` ; la
    récolte ne fait qu'étendre le vocabulaire d'un seul mot.
    """
    words = term.split()
    return 2 <= len(words) <= 4


def is_morphological_variant(candidate: str, referrer: str) -> bool:
    """Le terme récolté est-il le même mot avec un suffixe de plus ?

    « sibyllinement » est « sibyllin » plus un suffixe : le proposer comme
    découverte n'apprendrait rien, puisque le sens se déduit du mot déjà connu.
    On écarte ces variantes, sans écarter les mots plus courts de la même
    famille — « sibylle » reste, parce qu'il ne se déduit pas de « sibyllin ».

    La règle est volontairement grossière (six caractères communs et un mot plus
    long) : une analyse morphologique fine demanderait un lexique de suffixes
    qu'il faudrait maintenir, pour un gain marginal.
    """
    candidate_key = norm.normalize(candidate)
    referrer_key = norm.normalize(referrer)
    if len(referrer_key) < 6 or len(candidate_key) <= len(referrer_key):
        return False
    return candidate_key.startswith(referrer_key[:6])


def harvest_candidates(
    entries: list[Entry],
    known_ids: set[str],
    limit: int,
    per_category_limit: int,
) -> list[dict]:
    """Élargit la liste en suivant les liens que la source affirme.

    # Pourquoi cette récolte n'est pas une sélection au hasard

    Le cahier des charges interdit de piocher dans le dictionnaire pour remplir
    un quota. Cette récolte ne pioche pas : elle suit exactement la structure
    que le Wiktionnaire publie. Si la page de « monomaniaque » range
    « monomanie » parmi ses dérivés, alors « monomanie » appartient au même
    sujet — et le lien entre les deux fiches sera attesté, pas supposé.

    La catégorie est héritée de la fiche qui a mené au terme : le dérivé d'un
    mot littéraire est traité comme littéraire. C'est un choix, et il est
    enregistré dans le rapport pour être vérifiable.
    """
    harvested: list[dict] = []
    seen = set(known_ids)
    per_category: dict[str, int] = {}

    for entry in entries:
        # Les synonymes et antonymes viennent en premier : ce sont les seuls dont
        # une locution peut être récoltée, parce que la source affirme
        # l'équivalence.
        targets: list[tuple[str, bool]] = []
        targets.extend((target, True) for target in entry.synonym_targets)
        targets.extend((target, True) for target in entry.antonym_targets)
        targets.extend((target, False) for target, _ in entry.related_targets)
        targets.extend((target, False) for target in entry.etymology_links)

        for target, allows_expression in targets:
            if allows_expression and " " in target.strip():
                if not is_plausible_harvested_expression(target):
                    continue
            identifier = norm.slug(target)
            if not identifier or identifier in seen or not is_plausible_term(target):
                continue
            if is_morphological_variant(target, entry.term):
                continue
            if per_category.get(entry.category, 0) >= per_category_limit:
                continue
            seen.add(identifier)
            per_category[entry.category] = per_category.get(entry.category, 0) + 1
            harvested.append(
                {
                    "term": target.strip(),
                    "category": entry.category,
                    "kind": "expression" if " " in target.strip() else "word",
                    "harvestedFrom": entry.term,
                }
            )
            if len(harvested) >= limit:
                return harvested

    return harvested


# MARK: - Validation


def validate(entry: Entry, known_ids: set[str]) -> list[str]:
    """Invariants éditoriaux, alignés sur `LexicalEntry.validate()` côté Swift.

    Le contrôle est fait ici **et** dans l'application : la chaîne empêche une
    fiche fautive d'entrer dans le corpus, et l'application refuserait de
    l'afficher si elle y entrait malgré tout. Deux barrières pour une règle qui
    ne doit jamais céder.
    """
    issues: list[str] = []
    if not entry.term.strip():
        issues.append("terme vide")
    if not entry.id:
        issues.append("identifiant vide")
    if not entry.short_definition.value.strip():
        issues.append("définition courte absente")
    if len(entry.short_definition.value) > SHORT_DEFINITION_MAX_LENGTH:
        issues.append(
            f"définition courte trop longue ({len(entry.short_definition.value)} caractères)"
        )
    if not entry.long_definition.value.strip():
        issues.append("définition longue absente")
    if len(entry.examples) > 2:
        issues.append(f"trop d'exemples ({len(entry.examples)})")
    if not (
        relations_module.MIN_RELATIONS
        <= len(entry.relations)
        <= relations_module.MAX_RELATIONS
    ):
        issues.append(f"nombre de termes associés hors plage ({len(entry.relations)})")
    if any(not relation.rationale.strip() for relation in entry.relations):
        issues.append("terme associé sans justification")
    if any(relation.target_id == entry.id for relation in entry.relations):
        issues.append("fiche liée à elle-même")
    if any(relation.target_id not in known_ids for relation in entry.relations):
        issues.append("terme associé absent du corpus")
    if not any(source.kind in ("wiktionary", "wikipedia") for source in entry.sources):
        issues.append("aucune source d'attribution")

    for example in entry.examples:
        if example.origin == "vocabulle":
            continue
        if not (example.attributed_to or example.source_title):
            issues.append("exemple attribué sans auteur ni source vérifiable")

    textual = [
        entry.short_definition,
        entry.long_definition,
        entry.usage_note,
        entry.etymology,
        entry.history,
    ]
    claims_wiktionary = any(
        field is not None and field.provenance == "wiktionary" for field in textual
    )
    if claims_wiktionary and not any(source.kind == "wiktionary" for source in entry.sources):
        issues.append("provenance Wiktionnaire sans source Wiktionnaire")

    if not 1 <= entry.difficulty <= 3:
        issues.append(f"difficulté hors plage ({entry.difficulty})")

    return issues


# MARK: - Écriture SQLite


def example_json(example) -> dict:
    """Exemple au format attendu par `Example` côté Swift.

    Les clés sont écrites à la main, en camelCase. `dataclasses.asdict`
    produirait ``attributed_to``, que le `JSONDecoder` de Swift ne rattacherait
    pas à ``attributedTo`` : la fiche entière échouerait à se décoder, et
    l'application afficherait « corpus inaccessible » sans que rien n'explique
    pourquoi. Le nom des clés est un contrat, pas un détail de style.
    """
    return {
        "text": example.text,
        "origin": example.origin,
        "attributedTo": example.attributed_to,
        "sourceTitle": example.source_title,
    }


def relation_json(relation) -> dict:
    """Relation au format attendu par `LexicalRelation` côté Swift."""
    return {
        "targetID": relation.target_id,
        "targetTerm": relation.target_term,
        "type": relation.type,
        "evidence": relation.evidence,
        "rationale": relation.rationale,
    }


def source_json(source) -> dict:
    """Source au format attendu par `SourceRef` côté Swift."""
    return {
        "kind": source.kind,
        "title": source.title,
        "url": source.url,
        "revisionID": source.revision_id,
        "fetchedAt": source.fetched_at,
        "license": source.license,
    }


def write_database(path: Path, entries: list[Entry], metadata: dict) -> None:
    """Écrit la base embarquée. Le fichier est recréé à chaque exécution."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)

    connection = sqlite3.connect(path)
    try:
        connection.executescript(
            """
            PRAGMA page_size = 4096;
            CREATE TABLE metadata (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE entries (
                id                    TEXT PRIMARY KEY,
                term                  TEXT NOT NULL,
                term_search           TEXT NOT NULL,
                search_text           TEXT NOT NULL,
                kind                  TEXT NOT NULL,
                category              TEXT NOT NULL,
                difficulty            INTEGER NOT NULL,
                grammar_part          TEXT,
                grammar_gender        TEXT,
                grammar_note          TEXT,
                grammar_ipa           TEXT,
                registers             TEXT NOT NULL,
                short_definition      TEXT NOT NULL,
                short_provenance      TEXT NOT NULL,
                long_definition       TEXT NOT NULL,
                long_provenance       TEXT NOT NULL,
                usage_note            TEXT,
                usage_note_provenance TEXT,
                etymology             TEXT,
                etymology_provenance  TEXT,
                history               TEXT,
                history_provenance    TEXT,
                examples              TEXT NOT NULL,
                relations             TEXT NOT NULL,
                sources               TEXT NOT NULL,
                tags                  TEXT NOT NULL
            );
            """
        )

        for key, value in metadata.items():
            connection.execute(
                "INSERT INTO metadata (key, value) VALUES (?, ?)",
                (key, value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, sort_keys=True)),
            )

        rows = []
        for entry in sorted(entries, key=lambda item: item.id):
            rows.append(
                (
                    entry.id,
                    entry.term,
                    norm.normalize(entry.term),
                    # L'index de recherche réunit le terme et la définition
                    # longue : chercher « monomanie » doit trouver
                    # « monomaniaque » même quand le mot n'apparaît que dans
                    # l'explication.
                    norm.normalize(f"{entry.term} {entry.long_definition.value}"),
                    entry.kind,
                    entry.category,
                    entry.difficulty,
                    entry.part_of_speech,
                    entry.gender,
                    entry.grammar_note,
                    entry.ipa,
                    json.dumps(list(entry.registers), ensure_ascii=False),
                    entry.short_definition.value,
                    entry.short_definition.provenance,
                    entry.long_definition.value,
                    entry.long_definition.provenance,
                    entry.usage_note.value if entry.usage_note else None,
                    entry.usage_note.provenance if entry.usage_note else None,
                    entry.etymology.value if entry.etymology else None,
                    entry.etymology.provenance if entry.etymology else None,
                    entry.history.value if entry.history else None,
                    entry.history.provenance if entry.history else None,
                    json.dumps(
                        [example_json(example) for example in entry.examples],
                        ensure_ascii=False,
                    ),
                    json.dumps(
                        [relation_json(relation) for relation in entry.relations],
                        ensure_ascii=False,
                    ),
                    json.dumps(
                        [source_json(source) for source in entry.sources],
                        ensure_ascii=False,
                    ),
                    json.dumps(list(entry.tags), ensure_ascii=False),
                )
            )

        connection.executemany(
            "INSERT INTO entries VALUES ("
            + ", ".join(["?"] * 26)
            + ")",
            rows,
        )
        # Index utilisé par le moteur de sélection : il lit une catégorie dans
        # l'ordre des identifiants, et c'est cet ordre qui rend le tirage
        # reproductible.
        connection.execute("CREATE INDEX idx_entries_category ON entries (category, id)")
        connection.execute("CREATE INDEX idx_entries_search ON entries (search_text)")
        connection.execute("ANALYZE")
        connection.commit()
        connection.execute("VACUUM")
    finally:
        connection.close()


# MARK: - Rapport


def build_report(
    entries: list[Entry],
    rejections: list[Rejection],
    stats: ExtractionStats,
    orphaned_relations: int,
    *,
    candidates_total: int,
    harvested: list[dict],
    requests: int,
    cache_hits: int,
    output: Path,
) -> dict:
    counts: dict[str, int] = {}
    for entry in entries:
        counts[entry.category] = counts.get(entry.category, 0) + 1

    short_lengths = [len(entry.short_definition.value) for entry in entries]
    relation_kinds: dict[str, int] = {}
    for entry in entries:
        for relation in entry.relations:
            relation_kinds[relation.type] = relation_kinds.get(relation.type, 0) + 1
    editorial_relations = sum(
        1 for entry in entries for relation in entry.relations if relation.evidence == "editorial"
    )

    try:
        database_path = str(output.relative_to(ROOT))
    except ValueError:
        database_path = str(output)

    return {
        "pipelineVersion": PIPELINE_VERSION,
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": now_iso8601(),
        "candidates": candidates_total,
        "harvested": harvested,
        "harvestedCount": len(harvested),
        "verifiedEntries": len(entries),
        "rejected": len(rejections),
        "rejections": [asdict(rejection) for rejection in rejections],
        "countsByCategory": counts,
        "shareByCategory": {
            category: round(count * 100 / len(entries), 1) if entries else 0.0
            for category, count in sorted(counts.items())
        },
        "shortDefinitionLength": {
            "min": min(short_lengths) if short_lengths else 0,
            "max": max(short_lengths) if short_lengths else 0,
            "limit": SHORT_DEFINITION_MAX_LENGTH,
            "overLimit": sum(1 for value in short_lengths if value > SHORT_DEFINITION_MAX_LENGTH),
        },
        "entriesWithEtymology": sum(1 for entry in entries if entry.etymology),
        "entriesWithExamples": sum(1 for entry in entries if entry.examples),
        "relationKinds": relation_kinds,
        "editorialRelations": editorial_relations,
        "orphanedRelationsRemoved": orphaned_relations,
        "unknownLabelTemplates": dict(
            sorted(stats.unknown_label_templates.items(), key=lambda item: -item[1])
        ),
        "missingFrenchSection": stats.missing_french_section,
        "missingDefinitions": stats.missing_definitions,
        "network": {"requests": requests, "cacheHits": cache_hits},
        "database": {
            "path": database_path,
            "bytes": output.stat().st_size if output.is_file() else 0,
        },
    }


def render_report(report: dict) -> str:
    lines = [
        "# Rapport de production du corpus",
        "",
        f"- Version de la chaîne : {report['pipelineVersion']}",
        f"- Fiches vérifiées : **{report['verifiedEntries']}** sur {report['candidates']} candidats",
        f"- Candidats écartés : {report['rejected']}",
        f"- Taille de la base : {report['database']['bytes'] / 1024:.0f} Kio",
        f"- Requêtes réseau : {report['network']['requests']} "
        f"(+{report['network']['cacheHits']} lectures de cache)",
        "",
        "## Répartition par catégorie",
        "",
        "| Catégorie | Fiches | Part |",
        "| --- | --- | --- |",
    ]
    for category, count in sorted(report["countsByCategory"].items()):
        lines.append(
            f"| {category} | {count} | {report['shareByCategory'].get(category, 0.0)} % |"
        )

    lines += [
        "",
        "## Qualité",
        "",
        f"- Définition courte : {report['shortDefinitionLength']['min']} à "
        f"{report['shortDefinitionLength']['max']} caractères "
        f"(limite {report['shortDefinitionLength']['limit']}, "
        f"{report['shortDefinitionLength']['overLimit']} dépassement(s))",
        f"- Fiches avec étymologie : {report['entriesWithEtymology']}",
        f"- Fiches avec au moins un exemple : {report['entriesWithExamples']}",
        f"- Relations attestées : "
        f"{sum(report['relationKinds'].values()) - report['editorialRelations']}",
        f"- Rapprochements éditoriaux : {report['editorialRelations']}",
        f"- Relations retirées faute de cible : {report['orphanedRelationsRemoved']}",
        "",
        "## Types de relations",
        "",
    ]
    for kind, count in sorted(report["relationKinds"].items()):
        lines.append(f"- {kind} : {count}")

    if report["unknownLabelTemplates"]:
        lines += [
            "",
            "## Étiquettes de modèle non reconnues",
            "",
            "Ces modèles apparaissaient en tête de définition sans être classés "
            "comme registre ni comme domaine ; ils ont été ignorés. Une occurrence "
            "élevée signale une étiquette à ajouter aux tables d'extraction.",
            "",
        ]
        for name, count in list(report["unknownLabelTemplates"].items())[:40]:
            lines.append(f"- `{name}` : {count}")

    if report["rejections"]:
        lines += ["", "## Candidats écartés", ""]
        for rejection in report["rejections"]:
            lines.append(f"- {rejection['term']} — {rejection['reason']}")

    return "\n".join(lines) + "\n"


# MARK: - Programme


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Produit le corpus embarqué de Vocabulle.")
    parser.add_argument("--candidates", type=Path, default=ROOT / "tools" / "corpus" / "candidates.json")
    parser.add_argument("--editorial", type=Path, default=ROOT / "tools" / "corpus" / "editorial_relations.json")
    parser.add_argument("--cache", type=Path, default=ROOT / "tools" / "corpus" / ".cache")
    parser.add_argument("--out", type=Path, default=ROOT / "Resources" / "vocabulle-corpus.sqlite")
    parser.add_argument("--report", type=Path, default=ROOT / "tools" / "corpus" / "report.json")
    parser.add_argument("--minimum", type=int, default=300, help="Nombre minimal de fiches exigé.")
    parser.add_argument("--limit", type=int, default=0, help="Ne traiter que les N premiers candidats.")
    parser.add_argument("--offline", action="store_true", help="N'utiliser que le cache local.")
    parser.add_argument("--cache-budget-mb", type=int, default=DEFAULT_CACHE_BUDGET_MB)
    parser.add_argument(
        "--harvest-max",
        type=int,
        default=700,
        help="Plafond de termes récoltés en suivant les liens attestés. 0 désactive la récolte.",
    )
    parser.add_argument(
        "--harvest-per-category",
        type=int,
        default=70,
        help="Plafond de termes récoltés par catégorie, pour que la récolte ne "
             "déséquilibre pas la répartition éditoriale.",
    )
    args = parser.parse_args(argv)

    candidates = load_candidates(args.candidates)
    if args.limit:
        candidates = candidates[: args.limit]

    client = MediaWikiClient(cache_dir=args.cache, offline=args.offline)
    try:
        pages = client.fetch_pages([candidate["term"] for candidate in candidates])
    except MediaWikiError as error:
        print(f"ÉCHEC RÉSEAU : {error}", file=sys.stderr)
        return 2

    stats = ExtractionStats()
    fetched_at = now_iso8601()
    entries: list[Entry] = []
    rejections: list[Rejection] = []
    seen_ids: set[str] = set()

    def extract_all(batch: list[dict], pages_by_term: dict) -> None:
        for candidate in batch:
            term = candidate["term"]
            page = pages_by_term.get(term)
            if page is None:
                rejections.append(Rejection(term=term, reason="page absente du Wiktionnaire"))
                continue

            entry, reason = extract_entry(
                term=term,
                category=candidate["category"],
                kind=candidate["kind"],
                wikitext=page.wikitext,
                page_title=page.title,
                revision_id=page.revision_id,
                fetched_at=fetched_at,
                source_url=f"https://fr.wiktionary.org/wiki/{page.title.replace(' ', '_')}",
                stats=stats,
            )
            if entry is None:
                rejections.append(Rejection(term=term, reason=reason or "extraction impossible"))
                continue
            if entry.id in seen_ids:
                rejections.append(
                    Rejection(term=term, reason=f"identifiant déjà pris ({entry.id})")
                )
                continue
            seen_ids.add(entry.id)
            entries.append(entry)

    extract_all(candidates, pages)

    # Deuxième vague : les termes que la source rattache aux précédents. Sans
    # elle, la plupart des fiches n'ont aucune cible à proposer et sont écartées
    # faute de deux termes associés — non parce qu'elles sont mauvaises, mais
    # parce que le corpus était trop étroit autour d'elles.
    harvested: list[dict] = []
    if args.harvest_max > 0:
        # La récolte se fait en deux vagues, et c'est nécessaire : « maniaque »
        # est ramené par « monomaniaque », mais sa propre page cite six termes
        # de plus. Une récolte en une seule passe, calculée sur les seules
        # graines, ne verrait jamais ces six termes — et « maniaque » se
        # retrouverait avec une seule relation, donc écarté, entraînant
        # « monomaniaque » avec lui. Deux sauts restent un voisinage : au-delà,
        # la liste cesse d'être éditoriale et devient un parcours automatique du
        # dictionnaire entier.
        for hop in range(2):
            remaining = args.harvest_max - len(harvested)
            if remaining <= 0:
                break
            batch = harvest_candidates(
                entries,
                seen_ids,
                limit=remaining,
                per_category_limit=args.harvest_per_category,
            )
            if not batch:
                break
            try:
                batch_pages = client.fetch_pages([item["term"] for item in batch])
            except MediaWikiError as error:
                print(f"Récolte interrompue au saut {hop + 1} : {error}", file=sys.stderr)
                break
            extract_all(batch, batch_pages)
            for item in batch:
                if item["term"] in batch_pages:
                    harvested.append({**item, "hop": hop + 1})

    # Relations, puis filtrage jusqu'à stabilisation : écarter une fiche peut
    # priver une autre d'une relation et la faire tomber sous le minimum.
    editorial = relations_module.load_editorial_pairs(args.editorial)
    orphaned = 0
    for _ in range(MAX_FILTER_ROUNDS):
        relations_module.build_relations(entries, editorial)
        known_ids = {entry.id for entry in entries}
        survivors: list[Entry] = []
        for entry in entries:
            before = len(entry.relations)
            entry.relations = [
                relation for relation in entry.relations if relation.target_id in known_ids
            ]
            orphaned += before - len(entry.relations)

            issues = validate(entry, known_ids)
            if issues:
                rejections.append(Rejection(term=entry.term, reason=" ; ".join(issues)))
            else:
                survivors.append(entry)
        if len(survivors) == len(entries):
            break
        entries = survivors
    else:
        print(
            f"Attention : le filtrage n'a pas convergé en {MAX_FILTER_ROUNDS} passes.",
            file=sys.stderr,
        )

    if len(entries) < args.minimum:
        print(
            f"ÉCHEC : {len(entries)} fiches vérifiées, minimum exigé {args.minimum}. "
            "Ne jamais compléter avec des fiches non vérifiées : mieux vaut annoncer "
            "le nombre réel que remplir un quota.",
            file=sys.stderr,
        )

    metadata = {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": fetched_at,
        "entryCount": len(entries),
        "countsByCategory": {
            category: sum(1 for entry in entries if entry.category == category)
            for category in ("literary", "expression", "conversation", "specialized")
        },
        "sourceProject": "fr.wiktionary.org",
        "licenseName": "CC BY-SA 4.0",
        "pipelineVersion": PIPELINE_VERSION,
    }

    write_database(args.out, entries, {"corpus": metadata, "schemaVersion": str(SCHEMA_VERSION)})
    client.prune_cache(args.cache_budget_mb * 1024 * 1024)

    report = build_report(
        entries,
        rejections,
        stats,
        orphaned,
        candidates_total=len(candidates) + len(harvested),
        harvested=harvested,
        requests=client.request_count,
        cache_hits=client.cache_hits,
        output=args.out,
    )
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (args.report.parent / "report.md").write_text(render_report(report), encoding="utf-8")

    print(render_report(report))
    return 0 if len(entries) >= args.minimum else 1


if __name__ == "__main__":
    sys.exit(main())
