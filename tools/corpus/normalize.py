"""Normalisation du texte pour la recherche.

Miroir exact de ``SearchNormalizer`` (Core/Corpus/TextNormalization.swift). Les
deux implémentations doivent produire la même chaîne, sinon « ephemere » ne
trouverait plus « éphémère » : la colonne ``search_text`` est remplie ici, la
requête est normalisée là-bas.

La comparaison des deux est vérifiée par ``scripts/validate_corpus.py`` sur un
échantillon : une divergence serait silencieuse autrement, et ne se verrait
qu'à l'usage, par une recherche qui ne trouve rien.
"""
from __future__ import annotations

import unicodedata


def normalize(text: str) -> str:
    """Forme canonique : sans diacritiques, en minuscules, ponctuation réduite.

    Les ligatures (``œ``, ``æ``) ne sont **pas** décomposées, ni ici ni dans
    l'implémentation Swift : ``folding(options: .diacriticInsensitive)`` les
    laisse intactes. Les décomposer d'un seul côté créerait précisément la
    divergence que ces deux fonctions doivent éviter.
    """
    decomposed = unicodedata.normalize("NFD", text)
    stripped = "".join(ch for ch in decomposed if not unicodedata.combining(ch))
    lowered = stripped.lower()

    out: list[str] = []
    last_was_space = True
    for ch in lowered:
        if ch.isalnum():
            out.append(ch)
            last_was_space = False
        elif not last_was_space:
            out.append(" ")
            last_was_space = True
    return "".join(out).rstrip()


def terms(query: str) -> list[str]:
    """Découpe une requête en mots normalisés non vides."""
    return [word for word in normalize(query).split(" ") if word]


def slug(term: str) -> str:
    """Identifiant stable d'une fiche, identique à ``EntryID.slug(from:)``.

    Translittération minimale et déterministe : pas de dépendance à la locale,
    pas de table de correspondance à maintenir. Le résultat sert de clé de lien
    profond et de clé d'historique, donc il ne doit jamais changer.
    """
    decomposed = unicodedata.normalize("NFD", term)
    stripped = "".join(ch for ch in decomposed if not unicodedata.combining(ch))
    lowered = stripped.lower()

    out: list[str] = []
    last_was_dash = False
    for ch in lowered:
        if ch.isascii() and ch.isalnum():
            out.append(ch)
            last_was_dash = False
        elif not last_was_dash and out:
            out.append("-")
            last_was_dash = True
    return "".join(out).rstrip("-")
