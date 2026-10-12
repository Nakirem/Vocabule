"""Chaîne de production du corpus Vocabulle.

Modules :

- :mod:`normalize` — normalisation du texte, miroir de l'implémentation Swift ;
- :mod:`http` — client MediaWiki avec cache, temporisation et reprise ;
- :mod:`wikitext` — analyse du wikitexte par appariement d'accolades ;
- :mod:`extract` — construction d'une fiche depuis une page ;
- :mod:`relations` — termes associés, avec justification ;
- :mod:`build` — orchestration, validation et écriture SQLite.

Le point d'entrée est ``python3 -m tools.corpus.build``.
"""

__all__ = ["normalize", "http", "wikitext", "extract", "relations", "build"]
