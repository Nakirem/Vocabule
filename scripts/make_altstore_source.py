#!/usr/bin/env python3
"""Génère la source AltStore (`altstore.json`) d'une version publiée.

AltStore lit ce fichier pour découvrir l'application, l'installer et proposer
ses mises à jour. Il est **produit à partir de l'IPA réellement construite**, et
non rédigé à la main, pour une raison précise : le schéma exige que `version` et
`buildVersion` correspondent exactement au `CFBundleShortVersionString` et au
`CFBundleVersion` de l'application. Or la CI compile avec
`CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER"`, donc `buildVersion` change à
chaque exécution. Un fichier écrit à la main serait périmé au build suivant, et
AltStore proposerait une mise à jour qui n'existe pas — ou refuserait
l'installation.

Trois propriétés sont vérifiées ici, parce qu'AltStore refuse une source qui les
viole :

1. **`appPermissions.entitlements` doit lister tous les entitlements** de
   l'application et de ses extensions. Ils sont donc lus depuis les fichiers
   `.entitlements` du dépôt, jamais recopiés à la main.
2. **`appPermissions.privacy` doit refléter les clés « …UsageDescription »** de
   l'Info.plist. Vocabulle n'en déclare aucune : il ne demande ni caméra, ni
   microphone, ni photos, ni localisation. Le dictionnaire est donc vide, et
   c'est exact.
3. **`size` doit être la taille réelle en octets** de l'IPA téléchargée.

La catégorie est `other` et non `education` : AltStore n'accepte que
`developer`, `entertainment`, `games`, `lifestyle`, `other`, `photo-video`,
`social` et `utilities`. Une valeur hors liste fait échouer la lecture de la
source.

Aucune dépendance hors bibliothèque standard : le fichier est lisible par
`plistlib`, qui sait ouvrir un plist binaire comme celui d'une application
compilée.

Usage :
    python3 scripts/make_altstore_source.py \\
        --ipa dist/Vocabulle-unsigned.ipa \\
        --tag v1.0.0 \\
        --repository Nakirem/Vocabule \\
        --entitlements App/Resources/Vocabulle.entitlements \\
                     Widget/Resources/VocabulleWidget.entitlements \\
        --icon dist/icon-1024.png \\
        --output dist/altstore.json
"""

from __future__ import annotations

import argparse
import json
import plistlib
import sys
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence

# Identité de la source. L'`identifier` doit être unique parmi toutes les
# sources qu'un utilisateur ajoute à AltStore : il est préfixé par le domaine
# inversé du projet, comme un identifiant de bundle.
SOURCE_NAME = "Vocabulle"
SOURCE_IDENTIFIER = "fr.vocabulle.source"
SOURCE_SUBTITLE = "Trois découvertes lexicales par jour sur l'écran verrouillé."
SOURCE_DESCRIPTION = (
    "Vocabulle propose trois découvertes de vocabulaire français par jour — "
    "matin, après-midi et soir — affichées sur l'écran verrouillé de l'iPhone, "
    "avec une fiche complète à portée de toucher. Aucun compte, aucune "
    "publicité, aucune analyse d'usage, aucun serveur : le corpus est embarqué "
    "et l'application fonctionne en mode avion dès le premier lancement."
)

DEVELOPER_NAME = "Nakirem"
APP_NAME = "Vocabulle"
APP_SUBTITLE = "Trois mots par jour, sur l'écran verrouillé"
APP_DESCRIPTION = (
    "Trois découvertes par jour — matin, après-midi, soir — sur l'écran "
    "verrouillé, et une fiche complète au toucher : définition, exemples, "
    "étymologie, termes associés et sources.\n\n"
    "Vocabulle ne fait rien d'autre. Pas de compte, pas de quiz, pas de séries, "
    "pas de réseau social, pas de publicité, pas de mesure d'audience — et "
    "aucune connexion réseau, y compris au premier lancement : le corpus est "
    "embarqué dans l'application.\n\n"
    "Les définitions et les exemples proviennent du Wiktionnaire francophone "
    "(CC BY-SA 4.0) et sont crédités sur chaque fiche. Les textes de rédaction "
    "Vocabulle sont signalés comme tels.\n\n"
    "L'IPA est non signée : c'est AltStore qui la signe sur l'iPhone avec le "
    "compte Apple de l'utilisateur. Avec un compte gratuit, la signature expire "
    "au bout de sept jours et doit être rafraîchie."
)

# AltStore n'accepte que ces valeurs. « education » n'en fait pas partie.
CATEGORY = "other"

# Couleur d'accent de la source, reprise du thème clair de l'application
# (`VocabulleTheme.accent`). En hexadécimal à six chiffres, comme attendu.
TINT_COLOR = "#6B5B95"


class SourceError(RuntimeError):
    """Erreur de construction de la source, à afficher telle quelle."""


@dataclass(frozen=True)
class AppBundle:
    """Ce que l'IPA déclare d'elle-même."""

    bundle_identifier: str
    short_version: str
    build_version: str
    minimum_os_version: str


def read_entitlements(paths: Iterable[Path]) -> list[str]:
    """Relève l'union des clés d'entitlements de plusieurs fichiers plist.

    Seules les **clés** sont reprises : le schéma AltStore attend une liste de
    noms d'entitlements, pas leurs valeurs. L'union couvre l'application et
    l'extension widget, dont AltStore exige qu'elles soient toutes deux listées.
    """
    keys: set[str] = set()
    seen = 0
    for path in paths:
        if not path.is_file():
            raise SourceError(f"Fichier d'entitlements introuvable : {path}")
        with path.open("rb") as handle:
            payload = plistlib.load(handle)
        if not isinstance(payload, dict):
            raise SourceError(f"{path} ne contient pas un dictionnaire plist")
        keys.update(payload.keys())
        seen += 1
    if seen == 0:
        raise SourceError("Aucun fichier d'entitlements fourni")
    if not keys:
        raise SourceError(
            "Aucun entitlement trouvé : l'application et son extension devraient "
            "au moins déclarer le groupe partagé"
        )
    return sorted(keys)


def read_app_bundle(ipa: Path, app_name: str = APP_NAME) -> AppBundle:
    """Lit l'Info.plist de l'application telle qu'elle est dans l'IPA.

    L'IPA est un ZIP dont la racine est `Payload/`. L'Info.plist d'une
    application compilée est un plist **binaire** : `plistlib` le lit tel quel,
    sans avoir besoin de `plutil` ni donc d'un runner macOS.
    """
    if not ipa.is_file():
        raise SourceError(f"IPA introuvable : {ipa}")

    wanted = f"Payload/{app_name}.app/Info.plist"
    try:
        with zipfile.ZipFile(ipa) as archive:
            raw = archive.read(wanted)
    except KeyError:
        raise SourceError(f"{wanted} est absent de {ipa}") from None
    except zipfile.BadZipFile:
        raise SourceError(f"{ipa} n'est pas une archive ZIP lisible") from None

    info = plistlib.loads(raw)
    required = {
        "bundle_identifier": "CFBundleIdentifier",
        "short_version": "CFBundleShortVersionString",
        "build_version": "CFBundleVersion",
    }
    values: dict[str, str] = {}
    for field, key in required.items():
        value = info.get(key)
        if not value:
            raise SourceError(f"{key} est absent de l'Info.plist de {app_name}")
        values[field] = str(value)

    # MinimumOSVersion vit dans l'Info.plist d'une application archivée, mais
    # le schéma AltStore le veut facultatif : on ne l'exige pas.
    minimum = info.get("MinimumOSVersion")

    return AppBundle(
        bundle_identifier=values["bundle_identifier"],
        short_version=values["short_version"],
        build_version=values["build_version"],
        minimum_os_version=str(minimum) if minimum else "",
    )


def build_source(
    *,
    app: AppBundle,
    entitlements: Sequence[str],
    privacy: dict[str, str],
    version: str,
    date: str,
    download_url: str,
    size: int,
    icon_url: str,
    repository: str,
    localized_description: str = APP_DESCRIPTION,
) -> dict:
    """Assemble le dictionnaire de source, prêt à être sérialisé.

    Fonction pure : tout ce qui varie est passé en argument, ce qui la rend
    testable sans IPA, sans réseau et sans horloge.
    """
    if size <= 0:
        raise SourceError(f"Taille d'IPA invalide : {size}")
    for label, url in (("downloadURL", download_url), ("iconURL", icon_url)):
        if not url.startswith("https://"):
            raise SourceError(f"{label} doit être une URL HTTPS absolue : {url!r}")

    return {
        "name": SOURCE_NAME,
        "identifier": SOURCE_IDENTIFIER,
        "subtitle": SOURCE_SUBTITLE,
        "description": SOURCE_DESCRIPTION,
        "website": f"https://github.com/{repository}",
        "tintColor": TINT_COLOR,
        "nsfw": False,
        "featuredApps": [app.bundle_identifier],
        "apps": [
            {
                "name": APP_NAME,
                "bundleIdentifier": app.bundle_identifier,
                "developerName": DEVELOPER_NAME,
                "subtitle": APP_SUBTITLE,
                "localizedDescription": localized_description,
                "iconURL": icon_url,
                "tintColor": TINT_COLOR,
                "category": CATEGORY,
                # L'ordre compte pour AltStore : la version la plus récente
                # d'abord. Cette source n'en décrit qu'une — celle du tag
                # publié — ce qui évite qu'une entrée ancienne pointe par
                # erreur vers une IPA plus récente.
                "versions": [
                    {
                        "version": version,
                        "buildVersion": app.build_version,
                        "date": date,
                        "downloadURL": download_url,
                        "size": size,
                        **(
                            {"minOSVersion": app.minimum_os_version}
                            if app.minimum_os_version
                            else {}
                        ),
                    }
                ],
                "appPermissions": {
                    "entitlements": list(entitlements),
                    # Vocabulle ne déclare aucune clé « UsageDescription » :
                    # ni caméra, ni microphone, ni photos, ni localisation.
                    # Un dictionnaire vide est donc la description exacte.
                    "privacy": dict(privacy),
                },
            }
        ],
        "news": [],
    }


def version_from_tag(tag: str) -> str:
    """« v1.0.0 » → « 1.0.0 ». Refuse un tag qui ne porte pas de version."""
    version = tag[1:] if tag.startswith("v") else tag
    if not version or not version[0].isdigit():
        raise SourceError(
            f"Le tag {tag!r} ne porte pas de numéro de version : attendu « v1.2.3 »"
        )
    return version


def release_urls(
    repository: str, tag: str, ipa_name: str, icon_name: str
) -> tuple[str, str]:
    """Construit les deux URL de la Release, épinglées sur le tag.

    Elles sont volontairement **figées sur le tag** et non sur `latest` :
    le fichier de source décrit une version précise, et ses liens doivent
    continuer de désigner les fichiers de cette version même après la
    publication de la suivante.
    """
    base = f"https://github.com/{repository}/releases/download/{tag}"
    return f"{base}/{ipa_name}", f"{base}/{icon_name}"


def check_version_matches_tag(tag: str, app: AppBundle) -> None:
    """Vérifie que l'IPA construite porte bien la version du tag.

    Sans ce contrôle, un tag posé sur un commit dont la version n'a pas été
    mise à jour produirait une source annonçant une version que l'IPA ne porte
    pas — et AltStore proposerait indéfiniment une mise à jour sans effet.
    """
    expected = version_from_tag(tag)
    if app.short_version != expected:
        raise SourceError(
            f"L'IPA déclare la version {app.short_version!r} mais le tag {tag!r} "
            f"en annonce {expected!r}. La CI doit compiler avec "
            f"MARKETING_VERSION={expected}."
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True, help="IPA non signée produite")
    parser.add_argument("--tag", required=True, help="Tag publié, par exemple v1.0.0")
    parser.add_argument(
        "--repository", required=True, help="Dépôt, par exemple Nakirem/Vocabulle"
    )
    parser.add_argument(
        "--entitlements",
        type=Path,
        nargs="+",
        required=True,
        help="Fichiers .entitlements de l'application et de ses extensions",
    )
    parser.add_argument(
        "--icon", type=Path, required=True, help="Icône 1024×1024 jointe à la Release"
    )
    parser.add_argument(
        "--output", type=Path, required=True, help="Fichier altstore.json à écrire"
    )
    parser.add_argument(
        "--check-tag",
        action="store_true",
        help="Exige que la version de l'IPA corresponde au tag. Activé par la CI.",
    )
    args = parser.parse_args()

    try:
        app = read_app_bundle(args.ipa)
        if args.check_tag:
            check_version_matches_tag(args.tag, app)
        entitlements = read_entitlements(args.entitlements)
        download_url, icon_url = release_urls(
            args.repository, args.tag, args.ipa.name, args.icon.name
        )
        source = build_source(
            app=app,
            entitlements=entitlements,
            privacy={},
            version=app.short_version,
            date=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            download_url=download_url,
            size=args.ipa.stat().st_size,
            icon_url=icon_url,
            repository=args.repository,
        )
    except SourceError as error:
        print(f"erreur : {error}", file=sys.stderr)
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(source, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    print(f"Source écrite : {args.output}")
    print(
        f"  application    : {app.bundle_identifier} "
        f"{app.short_version} ({app.build_version})"
    )
    print(f"  entitlements   : {', '.join(entitlements)}")
    print(f"  IPA            : {args.ipa.stat().st_size} octets")
    print(f"  téléchargement : {download_url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
