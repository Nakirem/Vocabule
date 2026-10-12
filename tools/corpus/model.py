"""Schéma stable du corpus.

Ces structures sont le contrat entre la chaîne de production et l'application :
chaque champ correspond à une colonne de ``entries`` et à un champ de
``LexicalEntry`` côté Swift. Ajouter un champ oblige à faire évoluer les deux,
ce qui est exactement le but — un schéma qui se modifierait d'un seul côté
produirait une base que l'application ne saurait pas lire.

Chaque bloc de texte porte sa **provenance**. C'est une exigence éditoriale :
un texte repris du Wiktionnaire est sous CC BY-SA et doit être attribué, un
texte rédigé pour Vocabulle ne doit pas être présenté comme venant d'une source.
"""
from __future__ import annotations

from dataclasses import dataclass, field

#: Provenances possibles d'un bloc de texte, alignées sur `FieldProvenance`.
PROVENANCE_WIKTIONARY = "wiktionary"
PROVENANCE_WIKIPEDIA = "wikipedia"
PROVENANCE_EDITORIAL = "editorial"

#: Origines possibles d'un exemple, alignées sur `ExampleOrigin`.
ORIGIN_WIKTIONARY = "wiktionary"
ORIGIN_WIKIPEDIA = "wikipedia"
ORIGIN_VOCABULLE = "vocabulle"

#: Licence des contenus repris du Wiktionnaire.
WIKTIONARY_LICENSE = "CC BY-SA 4.0"

#: Longueur maximale de la définition courte, alignée sur
#: `LexicalEntry.shortDefinitionMaxLength`. Le widget la tronque sans prévenir :
#: on préfère contraindre ici plutôt que d'afficher une phrase coupée sur
#: l'écran verrouillé.
SHORT_DEFINITION_MAX_LENGTH = 120


@dataclass(frozen=True)
class TextField:
    """Texte affiché, avec sa provenance."""

    value: str
    provenance: str


@dataclass(frozen=True)
class Source:
    """Référence vérifiable vers la source d'un contenu."""

    kind: str
    title: str
    url: str | None
    revision_id: int | None
    fetched_at: str | None
    license: str | None


@dataclass(frozen=True)
class Example:
    """Exemple d'emploi, avec sa provenance."""

    text: str
    origin: str
    attributed_to: str | None
    source_title: str | None


@dataclass(frozen=True)
class Relation:
    """Terme associé, avec la raison explicite du rapprochement."""

    target_id: str
    target_term: str
    type: str
    evidence: str
    rationale: str


@dataclass
class Entry:
    """Fiche lexicale complète, avant validation."""

    id: str
    term: str
    kind: str
    category: str
    difficulty: int
    part_of_speech: str | None
    gender: str | None
    grammar_note: str | None
    ipa: str | None
    registers: tuple[str, ...]
    tags: tuple[str, ...]
    short_definition: TextField
    long_definition: TextField
    usage_note: TextField | None
    etymology: TextField | None
    history: TextField | None
    examples: tuple[Example, ...]
    sources: tuple[Source, ...]
    relations: list[Relation] = field(default_factory=list)
    #: Etymon partagé, utilisé pour construire les liens « même origine ».
    etymon: str | None = None
    #: Siècle d'attestation, utilisé pour les liens « même époque ».
    century: str | None = None
    #: Domaines attestés, utilisés pour les liens « même contexte ».
    domains: tuple[str, ...] = ()
    #: Synonymes et antonymes cités dans les définitions, avant filtrage.
    synonym_targets: tuple[str, ...] = ()
    antonym_targets: tuple[str, ...] = ()
    #: Termes que la source elle-même place dans une section « apparentés » ou
    #: « dérivés ». C'est la source qui affirme le lien, pas nous : ces
    #: rapprochements sont donc attestés, et se distinguent d'un rapprochement
    #: éditorial. Le deuxième membre du couple est le nom de la section, pour
    #: que la justification puisse la citer exactement.
    related_targets: tuple[tuple[str, str], ...] = ()
    #: Termes cités dans l'étymologie. « monomaniaque » vient de « monomanie » :
    #: quand les deux fiches sont au corpus, le lien est documenté et vaut mieux
    #: qu'une parenté de sens devinée.
    etymology_links: tuple[str, ...] = ()
    #: Verbe ou nom partagé par plusieurs locutions (« faire florès »,
    #: « faire mouche »). Sert de dernier recours, en rapprochement éditorial
    #: assumé : c'est un fait observable, mais que la source n'énonce pas.
    shared_head: str | None = None


@dataclass(frozen=True)
class Rejection:
    """Candidat écarté, avec la raison exacte.

    Le rapport de validation les liste tous : un candidat disparu sans
    explication serait impossible à corriger.
    """

    term: str
    reason: str
