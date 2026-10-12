"""Client MediaWiki pour fr.wiktionary.org.

# Ce que ce module garantit

- **User-Agent identifiable.** La politique de Wikimedia exige qu'un client
  automatisé s'identifie et donne un moyen de le contacter. Un User-Agent
  générique de bibliothèque est un motif de blocage, à juste titre.
- **Limitation de débit.** Une seconde entre deux requêtes, y compris entre
  deux lots. Le corpus entier tient en une poignée de requêtes groupées, il n'y
  a donc aucune raison de presser le serveur.
- **Cache disque.** Une page déjà récupérée n'est pas redemandée. Le cache est
  borné et purgeable, et il vit à côté du corpus, jamais dans le bundle.
- **Reprise sur erreur.** 429 et 5xx déclenchent une attente exponentielle qui
  respecte l'en-tête ``Retry-After`` quand le serveur en fournit un.

# L'endpoint utilisé

``action=query&prop=revisions&rvslots=main&rvprop=content|ids|timestamp``

C'est un endpoint **générique** de l'API MediaWiki, documenté pour toutes les
éditions. Le cahier des charges interdit explicitement de transposer à
fr.wiktionary.org un endpoint d'extraction de définitions qui ne serait
documenté que pour l'édition anglaise : c'est pourquoi on récupère le wikitexte
brut et qu'on l'analyse nous-mêmes, plutôt que de demander au serveur une fiche
toute faite qui n'existe pas ici.
"""
from __future__ import annotations

import gzip
import hashlib
import json
import random
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

ENDPOINT = "https://fr.wiktionary.org/w/api.php"

#: Identification exigée par la politique d'utilisation de Wikimedia.
USER_AGENT = (
    "Vocabulle/0.1 (pipeline de constitution de corpus hors ligne; "
    "contact: vocabulle@example.invalid)"
)

#: Nombre de titres par requête. 50 est la limite usuelle du paramètre
#: ``titles`` ; on reste à 50 pour ne dépendre d'aucune configuration serveur.
BATCH_SIZE = 50

#: Délai minimal entre deux requêtes, en secondes.
MIN_INTERVAL = 1.0

#: Nombre de tentatives avant d'abandonner une requête.
MAX_ATTEMPTS = 5


class MediaWikiError(RuntimeError):
    """Erreur définitive d'une requête à l'API."""


@dataclass(frozen=True)
class PageRevision:
    """Contenu d'une page à une révision donnée."""

    title: str
    revision_id: int | None
    timestamp: str | None
    wikitext: str
    from_cache: bool = False


class MediaWikiClient:
    """Client minimal, sans dépendance externe, avec cache et temporisation."""

    def __init__(
        self,
        cache_dir: Path,
        endpoint: str = ENDPOINT,
        user_agent: str = USER_AGENT,
        min_interval: float = MIN_INTERVAL,
        offline: bool = False,
    ) -> None:
        self.cache_dir = Path(cache_dir)
        self.endpoint = endpoint
        self.user_agent = user_agent
        self.min_interval = min_interval
        self.offline = offline
        self._last_request_at = 0.0
        self.request_count = 0
        self.cache_hits = 0
        self.cache_dir.mkdir(parents=True, exist_ok=True)

    # MARK: - API publique

    def fetch_pages(self, titles: list[str]) -> dict[str, PageRevision]:
        """Récupère plusieurs pages, par lots, indexées par titre demandé.

        Les titres absents ou redirigés sont résolus : ``redirects=1`` fait
        suivre les redirections, et la table ``normalized``/``redirects`` de la
        réponse permet de rattacher chaque page à la demande d'origine. Sans ce
        rattachement, une page renommée serait comptée comme manquante.
        """
        result: dict[str, PageRevision] = {}
        unique = list(dict.fromkeys(titles))
        for start in range(0, len(unique), BATCH_SIZE):
            batch = unique[start:start + BATCH_SIZE]
            result.update(self._fetch_batch(batch))
        return result

    def prune_cache(self, max_bytes: int) -> int:
        """Ramène le cache sous la taille demandée, du plus ancien au plus récent.

        Renvoie le nombre de fichiers supprimés. Le cache ne contient que des
        réponses de l'API : le purger ne touche ni le corpus produit, ni quoi
        que ce soit de l'utilisateur.
        """
        entries = sorted(
            self.cache_dir.glob("*.json"),
            key=lambda path: path.stat().st_mtime,
        )
        total = sum(path.stat().st_size for path in entries)
        removed = 0
        for path in entries:
            if total <= max_bytes:
                break
            size = path.stat().st_size
            path.unlink(missing_ok=True)
            total -= size
            removed += 1
        return removed

    # MARK: - Requêtes

    def _fetch_batch(self, titles: list[str]) -> dict[str, PageRevision]:
        cache_key = hashlib.sha256("\n".join(titles).encode("utf-8")).hexdigest()[:32]
        cache_path = self.cache_dir / f"pages-{cache_key}.json"

        if cache_path.is_file():
            try:
                payload = json.loads(cache_path.read_text(encoding="utf-8"))
                self.cache_hits += 1
                return self._parse_payload(payload, from_cache=True)
            except (json.JSONDecodeError, KeyError, TypeError):
                # Un fichier de cache illisible est un incident sans gravité :
                # on le supprime et on redemande la page.
                cache_path.unlink(missing_ok=True)

        if self.offline:
            raise MediaWikiError(
                f"Mode hors ligne : {len(titles)} titre(s) absent(s) du cache "
                f"(premier : {titles[0]!r})."
            )

        payload = self._request(titles)
        cache_path.write_text(
            json.dumps(payload, ensure_ascii=False, sort_keys=True),
            encoding="utf-8",
        )
        return self._parse_payload(payload, from_cache=False)

    def _request(self, titles: list[str]) -> dict:
        params = {
            "action": "query",
            "format": "json",
            "formatversion": "2",
            "prop": "revisions",
            "rvslots": "main",
            "rvprop": "content|ids|timestamp",
            "redirects": "1",
            "titles": "|".join(titles),
        }
        url = f"{self.endpoint}?{urllib.parse.urlencode(params)}"
        last_error: Exception | None = None

        for attempt in range(MAX_ATTEMPTS):
            self._respect_rate_limit()
            try:
                request = urllib.request.Request(
                    url,
                    headers={
                        "User-Agent": self.user_agent,
                        "Accept": "application/json",
                        "Accept-Encoding": "gzip",
                    },
                )
                with urllib.request.urlopen(request, timeout=45) as response:
                    raw = response.read()
                    if response.headers.get("Content-Encoding") == "gzip":
                        raw = gzip.decompress(raw)
                self.request_count += 1
                return json.loads(raw.decode("utf-8"))
            except urllib.error.HTTPError as error:
                last_error = error
                if error.code in (429, 500, 502, 503, 504):
                    self._backoff(attempt, error.headers.get("Retry-After"))
                    continue
                raise MediaWikiError(
                    f"HTTP {error.code} sur {len(titles)} titre(s) : {error.reason}"
                ) from error
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
                last_error = error
                self._backoff(attempt, None)
                continue

        raise MediaWikiError(
            f"Échec après {MAX_ATTEMPTS} tentatives sur {len(titles)} titre(s) : {last_error}"
        )

    def _respect_rate_limit(self) -> None:
        elapsed = time.monotonic() - self._last_request_at
        if elapsed < self.min_interval:
            time.sleep(self.min_interval - elapsed)
        self._last_request_at = time.monotonic()

    @staticmethod
    def _backoff(attempt: int, retry_after: str | None) -> None:
        """Attente avant nouvelle tentative.

        ``Retry-After`` prime sur le calcul exponentiel : c'est le serveur qui
        sait quand il sera de nouveau disponible. On ajoute une gigue pour que
        plusieurs exécutions simultanées ne repartent pas à la même seconde.
        """
        if retry_after:
            try:
                delay = float(retry_after)
            except ValueError:
                delay = 2.0 ** attempt
        else:
            delay = 2.0 ** attempt
        time.sleep(min(delay, 60.0) + random.uniform(0, 0.75))

    # MARK: - Décodage

    def _parse_payload(self, payload: dict, from_cache: bool) -> dict[str, PageRevision]:
        query = payload.get("query") or {}
        pages_by_title: dict[str, dict] = {}
        for page in query.get("pages", []):
            title = page.get("title")
            if title:
                pages_by_title[title] = page

        # Un titre demandé peut avoir été normalisé (casse, espaces) puis
        # redirigé. On remonte la chaîne pour que l'appelant retrouve sa clé.
        alias: dict[str, str] = {}
        for entry in query.get("normalized", []):
            alias[entry["from"]] = entry["to"]
        for entry in query.get("redirects", []):
            alias[entry["from"]] = entry["to"]

        def resolve(title: str) -> str:
            seen: set[str] = set()
            current = title
            while current in alias and current not in seen:
                seen.add(current)
                current = alias[current]
            return current

        result: dict[str, PageRevision] = {}
        for requested in set(alias) | set(pages_by_title):
            page = pages_by_title.get(resolve(requested))
            if page is None or "missing" in page:
                continue
            revisions = page.get("revisions") or []
            if not revisions:
                continue
            revision = revisions[0]
            content = (revision.get("slots") or {}).get("main", {}).get("content")
            if not content:
                continue
            result[requested] = PageRevision(
                title=page["title"],
                revision_id=revision.get("revid"),
                timestamp=revision.get("timestamp"),
                wikitext=content,
                from_cache=from_cache,
            )
        return result
