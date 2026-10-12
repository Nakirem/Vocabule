"""Construction des termes associés.

# La règle du cahier des charges

« Les liens associés pointent vers des entrées existantes » et chaque
rapprochement porte une justification défendable. Le cahier des charges
distingue explicitement un **lien attesté** — étymologie commune, synonymie
documentée, même domaine étiqueté par la source — d'un **rapprochement
éditorial** assumé par Vocabulle.

Trois conséquences dans ce module :

1. Aucune relation ne pointe vers une fiche absente du corpus. Un lien mort
   serait pire qu'une absence de lien.
2. Chaque phrase de justification énonce le fait qui la fonde, et nomme la
   source de ce fait. « Ces deux mots vont bien ensemble » n'y figure jamais.
3. Les rapprochements éditoriaux viennent d'une table explicite et relue, pas
   d'une heuristique : ils sont assumés, donc ils s'écrivent à la main.
"""
from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path

from . import normalize as norm
from .model import Entry, Relation

#: Bornes imposées par le modèle Swift (`relationCountOutOfRange`).
MIN_RELATIONS = 2
MAX_RELATIONS = 4

#: Nombre maximal de relations « même contexte » et « même époque ».
#:
#: Sans plafond, un terme d'un domaine très représenté recevrait quatre liens
#: vers le même domaine, ce qui n'apprendrait rien. On en garde deux au plus, et
#: les liens forts — synonymie, antonymie, étymologie — passent devant.
MAX_WEAK_RELATIONS = 2

EVIDENCE_ATTESTED = "attested"
EVIDENCE_EDITORIAL = "editorial"

TYPE_SYNONYM = "synonym"
TYPE_ANTONYM = "antonym"
TYPE_SAME_ORIGIN = "sameOrigin"
TYPE_SAME_ERA = "sameEra"
TYPE_SAME_CONTEXT = "sameContext"


def load_editorial_pairs(path: Path | None) -> dict[str, list[dict]]:
    """Rapprochements éditoriaux écrits à la main, indexés par fiche source.

    Le fichier est facultatif. Son absence n'est pas une erreur : elle signifie
    simplement qu'aucun rapprochement éditorial n'a encore été rédigé, et le
    corpus se contente alors de liens attestés.
    """
    if path is None or not path.is_file():
        return {}
    payload = json.loads(path.read_text(encoding="utf-8"))
    index: dict[str, list[dict]] = defaultdict(list)
    for pair in payload.get("pairs", []):
        # Les termes sont convertis en identifiants ici, jamais à la main dans
        # le fichier : « nœud gordien » donne « n-ud-gordien », et une
        # identifiant écrit de mémoire ne correspondrait à rien — la relation
        # serait alors silencieusement ignorée.
        index[norm.slug(pair["from"])].append({**pair, "to": norm.slug(pair["to"])})
    return index


def build_pair_graphs(entries: list[Entry], by_term: dict[str, Entry]):
    """Graphes **symétriques** des liens que la source affirme.

    # Pourquoi la symétrie est nécessaire

    Les liens du Wiktionnaire sont écrits dans un sens : la page de
    « monomaniaque » cite « monomanie » et « maniaque » dans son étymologie,
    mais la page de « maniaque » ne cite pas « monomaniaque ». En lisant ces
    liens comme des arcs orientés, on obtient un graphe si peu dense que le
    filtrage des fiches à deux relations finit par tout éliminer : chaque
    suppression retire des liens, ce qui justifie de nouvelles suppressions.

    Or un rapport d'étymologie, d'apparentement ou de synonymie est une
    propriété de la **paire**. Que la source l'énonce d'un côté ou de l'autre ne
    change rien à ce qu'elle affirme. Le graphe est donc rendu symétrique, et
    chaque arête retient de quelle page vient l'affirmation — pour que la
    justification puisse citer la bonne.
    """
    etymology: dict[str, dict[str, str]] = defaultdict(dict)
    related: dict[str, dict[str, tuple[str, str]]] = defaultdict(dict)
    synonyms: dict[str, set[str]] = defaultdict(set)
    antonyms: dict[str, set[str]] = defaultdict(set)

    def pair(target: Entry, other: Entry) -> bool:
        return other.id != target.id

    for entry in entries:
        for target in entry.etymology_links:
            other = by_term.get(norm.normalize(target))
            if other is None or not pair(entry, other):
                continue
            etymology[entry.id][other.id] = entry.term
            etymology[other.id].setdefault(entry.id, entry.term)

        for target, label in entry.related_targets:
            other = by_term.get(norm.normalize(target))
            if other is None or not pair(entry, other):
                continue
            related[entry.id][other.id] = (entry.term, label)
            related[other.id].setdefault(entry.id, (entry.term, label))

        for target in entry.synonym_targets:
            other = by_term.get(norm.normalize(target))
            if other is None or not pair(entry, other):
                continue
            synonyms[entry.id].add(other.id)
            synonyms[other.id].add(entry.id)

        for target in entry.antonym_targets:
            other = by_term.get(norm.normalize(target))
            if other is None or not pair(entry, other):
                continue
            antonyms[entry.id].add(other.id)
            antonyms[other.id].add(entry.id)

    return etymology, related, synonyms, antonyms


def build_relations(entries: list[Entry], editorial: dict[str, list[dict]]) -> None:
    """Attache à chaque fiche ses relations. Modifie ``entries`` en place."""
    by_id = {entry.id: entry for entry in entries}
    by_term: dict[str, Entry] = {}
    for entry in entries:
        by_term.setdefault(norm.normalize(entry.term), entry)

    etymology_graph, related_graph, synonym_graph, antonym_graph = build_pair_graphs(
        entries, by_term
    )

    by_etymon: dict[str, list[Entry]] = defaultdict(list)
    by_domain: dict[str, list[Entry]] = defaultdict(list)
    by_century: dict[str, list[Entry]] = defaultdict(list)
    by_head: dict[str, list[Entry]] = defaultdict(list)
    for entry in entries:
        if entry.etymon:
            by_etymon[entry.etymon].append(entry)
        for domain in entry.domains:
            by_domain[domain].append(entry)
        if entry.century:
            by_century[entry.century].append(entry)
        if entry.shared_head:
            by_head[entry.shared_head].append(entry)

    for entry in entries:
        candidates: list[Relation] = []

        # 1. Synonymie et antonymie documentées par la source.
        for other_id in sorted(synonym_graph.get(entry.id, set())):
            other = by_id[other_id]
            candidates.append(
                Relation(
                    target_id=other.id,
                    target_term=other.term,
                    type=TYPE_SYNONYM,
                    evidence=EVIDENCE_ATTESTED,
                    rationale=(
                        "Synonyme attesté par le Wiktionnaire : les deux termes y "
                        "sont donnés comme équivalents."
                    ),
                )
            )
        for other_id in sorted(antonym_graph.get(entry.id, set())):
            other = by_id[other_id]
            candidates.append(
                Relation(
                    target_id=other.id,
                    target_term=other.term,
                    type=TYPE_ANTONYM,
                    evidence=EVIDENCE_ATTESTED,
                    rationale=(
                        "Antonyme attesté par le Wiktionnaire : les deux termes y "
                        "sont donnés comme opposés."
                    ),
                )
            )

        # 2. Termes cités dans une étymologie. « monomaniaque » vient de
        #    « monomanie » : quand les deux fiches sont au corpus, la source
        #    documente le lien, on n'a rien à supposer.
        for other_id, source_term in sorted(etymology_graph.get(entry.id, {}).items()):
            other = by_id[other_id]
            candidates.append(
                Relation(
                    target_id=other.id,
                    target_term=other.term,
                    type=TYPE_SAME_ORIGIN,
                    evidence=EVIDENCE_ATTESTED,
                    rationale=(
                        f"Le Wiktionnaire rattache l'étymologie de « {source_term} » "
                        f"à « {other.term} »."
                    ),
                )
            )

        # 3. Termes que la source range elle-même dans une section
        #    « apparentés » ou « dérivés ». C'est la source qui affirme le lien.
        for other_id, (source_term, section_label) in sorted(
            related_graph.get(entry.id, {}).items()
        ):
            other = by_id[other_id]
            candidates.append(
                Relation(
                    target_id=other.id,
                    target_term=other.term,
                    type=TYPE_SAME_ORIGIN,
                    evidence=EVIDENCE_ATTESTED,
                    rationale=(
                        f"Le Wiktionnaire place « {entry.term} » et « {other.term} » "
                        f"dans la même section « {section_label} » de la page "
                        f"« {source_term} »."
                    ),
                )
            )

        # 4. Même étymon partagé, quand les deux pages remontent au même mot.
        if entry.etymon:
            language, _, word = entry.etymon.partition(":")
            for other in by_etymon.get(entry.etymon, []):
                if other.id == entry.id:
                    continue
                candidates.append(
                    Relation(
                        target_id=other.id,
                        target_term=other.term,
                        type=TYPE_SAME_ORIGIN,
                        evidence=EVIDENCE_ATTESTED,
                        rationale=(
                            f"Même origine : le Wiktionnaire rattache les deux termes "
                            f"à « {word} » ({language})."
                        ),
                    )
                )

        # 5. Même domaine étiqueté, même siècle d'attestation, puis même
        #    construction. Les trois sont plafonnés ensemble : ce sont les liens
        #    les moins spécifiques, et quatre « même domaine » n'apprendraient
        #    rien à personne.
        weak_budget = MAX_WEAK_RELATIONS
        for domain in entry.domains:
            if weak_budget <= 0:
                break
            for other in _neighbours(entry, by_domain.get(domain, []), limit=weak_budget):
                candidates.append(
                    Relation(
                        target_id=other.id,
                        target_term=other.term,
                        type=TYPE_SAME_CONTEXT,
                        evidence=EVIDENCE_ATTESTED,
                        rationale=(
                            f"Même domaine : le Wiktionnaire étiquette les deux fiches "
                            f"« {domain} »."
                        ),
                    )
                )
                weak_budget -= 1
        if weak_budget > 0 and entry.century:
            for other in _neighbours(entry, by_century.get(entry.century, []), limit=weak_budget):
                candidates.append(
                    Relation(
                        target_id=other.id,
                        target_term=other.term,
                        type=TYPE_SAME_ERA,
                        evidence=EVIDENCE_ATTESTED,
                        rationale=(
                            f"Même époque : le Wiktionnaire date les deux termes de "
                            f"{entry.century}."
                        ),
                    )
                )

        if weak_budget > 0 and entry.shared_head:
            # Dernier recours, et le seul rapprochement éditorial produit
            # automatiquement : deux locutions construites sur le même verbe se
            # répondent, mais le Wiktionnaire ne le dit nulle part. On l'assume
            # comme nôtre, plutôt que de le présenter comme attesté.
            for other in by_head.get(entry.shared_head, []):
                if other.id == entry.id:
                    continue
                candidates.append(
                    Relation(
                        target_id=other.id,
                        target_term=other.term,
                        type=TYPE_SAME_CONTEXT,
                        evidence=EVIDENCE_EDITORIAL,
                        rationale=(
                            f"Rapprochement éditorial : les deux locutions se "
                            f"construisent sur « {entry.shared_head} »."
                        ),
                    )
                )
                weak_budget -= 1

        # 6. Rapprochements éditoriaux, rédigés à la main.
        for pair in editorial.get(entry.id, []):
            target = by_id.get(pair["to"])
            if target is None or target.id == entry.id:
                continue
            candidates.append(
                Relation(
                    target_id=target.id,
                    target_term=target.term,
                    type=pair.get("type", "contrast"),
                    evidence=EVIDENCE_EDITORIAL,
                    rationale=pair["rationale"],
                )
            )

        entry.relations = _select(candidates, entry.id)


def _neighbours(entry: Entry, pool: list[Entry], limit: int) -> list[Entry]:
    """Voisins déterministes d'une fiche dans un ensemble.

    On prend les fiches dont l'identifiant suit immédiatement le sien, en
    revenant au début à la fin de la liste. Prendre toujours les premières par
    ordre alphabétique serait plus simple, mais concentrerait tous les liens sur
    les mêmes quelques termes ; le parcours circulaire répartit les
    rapprochements sans rien perdre du déterminisme : la même entrée produit
    toujours les mêmes voisins.
    """
    unique = {other.id: other for other in pool if other.id != entry.id}
    ordered = [unique[key] for key in sorted(unique)]
    if not ordered:
        return []

    start = 0
    for index, other in enumerate(ordered):
        if other.id > entry.id:
            start = index
            break
    return [ordered[(start + offset) % len(ordered)] for offset in range(min(limit, len(ordered)))]


def _select(candidates: list[Relation], entry_id: str) -> list[Relation]:
    """Dédoublonne par cible, en gardant la première relation rencontrée.

    L'ordre de construction est un ordre de force : synonymie d'abord,
    étymologie ensuite, domaine et époque en dernier. La première relation
    rencontrée pour une cible donnée est donc la mieux fondée.
    """
    best: dict[str, Relation] = {}
    for relation in candidates:
        if relation.target_id == entry_id:
            continue
        if not relation.rationale.strip():
            continue
        best.setdefault(relation.target_id, relation)
    return list(best.values())[:MAX_RELATIONS]
