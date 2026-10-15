"""Tests de la génération de la source AltStore.

# Pourquoi ces tests comptent

AltStore refuse une source mal formée — mais le refus arrive **sur l'iPhone de
l'utilisateur**, au moment où il colle l'URL, sous la forme d'un message
d'erreur laconique. Aucune de ces pannes n'est visible en CI : le fichier est
produit, il est du JSON valide, et il ne fonctionne pas.

Trois familles de refus sont vérifiées ici, parce que ce sont celles qui se
produisent réellement :

1. **Un champ obligatoire manquant.** Le schéma publié par AltStore distingue
   les champs obligatoires des facultatifs ; les listes ci-dessous en sont la
   transcription littérale, pour qu'une évolution du schéma se voie ici.
2. **Des entitlements qui ne correspondent pas à ceux de l'application.**
   AltStore compare ce qui est déclaré à ce que contient l'IPA et refuse
   d'installer en cas d'écart. Les entitlements sont donc lus depuis les
   fichiers `.entitlements` du dépôt, et ces tests le vérifient.
3. **Une version qui ne correspond pas à l'IPA.** Une source qui annonce une
   version que le binaire ne porte pas fait proposer indéfiniment une mise à
   jour sans effet.

Écrits en ``unittest`` de la bibliothèque standard, comme le reste du dossier :
la CI les lance avec ``python3 -m unittest discover``.
"""

from __future__ import annotations

import json
import plistlib
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "make_altstore_source.py"

APP_IDENTIFIER = "fr.vocabulle.app"
WIDGET_IDENTIFIER = "fr.vocabulle.app.widget"
APP_GROUP = "group.fr.vocabulle.app"

# Transcription du schéma publié par AltStore. Les champs facultatifs n'y
# figurent pas : ce qui est testé est ce sans quoi l'installation échoue.
REQUIRED_SOURCE_FIELDS = ("name", "identifier", "apps")
REQUIRED_APP_FIELDS = (
    "name",
    "bundleIdentifier",
    "developerName",
    "localizedDescription",
    "iconURL",
    "versions",
    "appPermissions",
)
REQUIRED_VERSION_FIELDS = (
    "version",
    "buildVersion",
    "date",
    "downloadURL",
    "size",
)

# AltStore n'accepte que ces catégories. « education », qui serait le choix
# naturel pour une application de vocabulaire, n'en fait pas partie.
ALLOWED_CATEGORIES = (
    "developer",
    "entertainment",
    "games",
    "lifestyle",
    "other",
    "photo-video",
    "social",
    "utilities",
)

REAL_ENTITLEMENTS = (
    ROOT / "App" / "Resources" / "Vocabulle.entitlements",
    ROOT / "Widget" / "Resources" / "VocabulleWidget.entitlements",
)


def write_ipa(
    directory: Path,
    *,
    identifier: str = APP_IDENTIFIER,
    short_version: str = "1.0.0",
    build_version: str = "42",
    minimum_os: str | None = "17.0",
) -> Path:
    """Fabrique une IPA minimale : un ZIP dont la racine est Payload/.

    L'Info.plist est délibérément écrit en **binaire**, comme celui d'une
    application réellement compilée : un test qui n'utiliserait qu'un plist XML
    ne prouverait pas que le script sait lire ce que la CI produit.
    """
    info = {
        "CFBundleIdentifier": identifier,
        "CFBundleName": "Vocabulle",
        "CFBundleExecutable": "Vocabulle",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": short_version,
        "CFBundleVersion": build_version,
    }
    if minimum_os is not None:
        info["MinimumOSVersion"] = minimum_os

    ipa = directory / "Vocabulle-unsigned.ipa"
    with zipfile.ZipFile(ipa, "w") as archive:
        archive.writestr(
            "Payload/Vocabulle.app/Info.plist",
            plistlib.dumps(info, fmt=plistlib.FMT_BINARY),
        )
    return ipa


def write_entitlements(directory: Path, name: str, groups: list[str]) -> Path:
    path = directory / name
    path.write_bytes(plistlib.dumps({"com.apple.security.application-groups": groups}))
    return path


def run_script(
    ipa: Path,
    output: Path,
    entitlements: list[Path],
    *,
    tag: str = "v1.0.0",
    icon: Path | None = None,
    check_tag: bool = False,
    repository: str = "Nakirem/Vocabule",
) -> subprocess.CompletedProcess:
    """Exécute le script comme le ferait la CI, et renvoie le résultat brut."""
    command = [
        sys.executable,
        str(SCRIPT),
        "--ipa",
        str(ipa),
        "--tag",
        tag,
        "--repository",
        repository,
        "--entitlements",
        *[str(path) for path in entitlements],
        "--icon",
        str(icon or (ipa.parent / "icon-1024.png")),
        "--output",
        str(output),
    ]
    if check_tag:
        command.append("--check-tag")
    return subprocess.run(command, capture_output=True, text=True, cwd=ROOT)


class SourceGenerationTests(unittest.TestCase):
    """Cas nominal : l'IPA et ses entitlements, tels que la CI les produit."""

    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory()
        self.directory = Path(self._temp.name)
        self.ipa = write_ipa(self.directory)
        self.entitlements = [
            write_entitlements(self.directory, "Vocabulle.entitlements", [APP_GROUP]),
            write_entitlements(
                self.directory, "VocabulleWidget.entitlements", [APP_GROUP]
            ),
        ]
        self.output = self.directory / "altstore.json"
        self.result = run_script(self.ipa, self.output, self.entitlements)
        self.assertEqual(self.result.returncode, 0, self.result.stderr)
        self.source = json.loads(self.output.read_text(encoding="utf-8"))
        self.app = self.source["apps"][0]
        self.version = self.app["versions"][0]

    def tearDown(self) -> None:
        self._temp.cleanup()

    def test_source_is_written_and_is_valid_json(self) -> None:
        self.assertTrue(self.output.is_file())

    def test_source_carries_every_required_field(self) -> None:
        for field in REQUIRED_SOURCE_FIELDS:
            self.assertIn(field, self.source, f"champ de source obligatoire : {field}")
        for field in REQUIRED_APP_FIELDS:
            self.assertIn(field, self.app, f"champ d'application obligatoire : {field}")
        for field in REQUIRED_VERSION_FIELDS:
            self.assertIn(field, self.version, f"champ de version obligatoire : {field}")

    def test_category_is_one_that_altstore_accepts(self) -> None:
        self.assertIn(self.app["category"], ALLOWED_CATEGORIES)

    def test_bundle_identifier_comes_from_the_ipa(self) -> None:
        self.assertEqual(self.app["bundleIdentifier"], APP_IDENTIFIER)
        self.assertEqual(self.source["featuredApps"], [APP_IDENTIFIER])
        self.assertNotEqual(self.app["bundleIdentifier"], WIDGET_IDENTIFIER)

    def test_version_and_build_version_come_from_the_ipa(self) -> None:
        self.assertEqual(self.version["version"], "1.0.0")
        self.assertEqual(self.version["buildVersion"], "42")

    def test_size_is_the_real_ipa_size_in_bytes(self) -> None:
        self.assertEqual(self.version["size"], self.ipa.stat().st_size)
        self.assertIsInstance(self.version["size"], int)

    def test_minimum_os_version_is_reported_when_present(self) -> None:
        self.assertEqual(self.version["minOSVersion"], "17.0")

    def test_minimum_os_version_is_omitted_when_absent(self) -> None:
        # Une IPA écrite dans un sous-dossier, pour ne pas écraser celle du cas
        # nominal : `write_ipa` nomme toujours son fichier de la même façon.
        folder = self.directory / "sans-minimum"
        folder.mkdir()
        ipa = write_ipa(folder, minimum_os=None)
        output = self.directory / "sans-minimum.json"
        result = run_script(ipa, output, self.entitlements)
        self.assertEqual(result.returncode, 0, result.stderr)
        version = json.loads(output.read_text(encoding="utf-8"))["apps"][0]["versions"][0]
        self.assertNotIn("minOSVersion", version)

    def test_entitlements_are_listed_for_app_and_extension(self) -> None:
        declared = self.app["appPermissions"]["entitlements"]
        self.assertIn("com.apple.security.application-groups", declared)

    def test_privacy_is_empty_because_no_usage_description_is_declared(self) -> None:
        # Vocabulle ne demande ni caméra, ni microphone, ni photos, ni
        # localisation : l'Info.plist ne porte aucune clé « …UsageDescription ».
        self.assertEqual(self.app["appPermissions"]["privacy"], {})

    def test_urls_are_https_and_pinned_to_the_repository_and_tag(self) -> None:
        self.assertEqual(
            self.version["downloadURL"],
            "https://github.com/Nakirem/Vocabule/releases/download/v1.0.0/"
            + self.ipa.name,
        )
        self.assertEqual(
            self.app["iconURL"],
            "https://github.com/Nakirem/Vocabule/releases/download/v1.0.0/"
            "icon-1024.png",
        )

    def test_date_is_an_iso_8601_utc_timestamp(self) -> None:
        self.assertRegex(
            self.version["date"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"
        )

    def test_a_single_version_is_described(self) -> None:
        # La source décrit la version publiée, pas un historique : une entrée
        # ancienne pointerait vers une IPA plus récente que celle qu'elle
        # annonce.
        self.assertEqual(len(self.app["versions"]), 1)


class SourceRefusalTests(unittest.TestCase):
    """Les refus : ce que le script doit rejeter plutôt que produire."""

    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory()
        self.directory = Path(self._temp.name)
        self.ipa = write_ipa(self.directory)
        self.entitlements = [
            write_entitlements(self.directory, "Vocabulle.entitlements", [APP_GROUP])
        ]

    def tearDown(self) -> None:
        self._temp.cleanup()

    def test_a_tag_disagreeing_with_the_ipa_is_refused(self) -> None:
        output = self.directory / "altstore.json"
        result = run_script(
            self.ipa, output, self.entitlements, tag="v2.0.0", check_tag=True
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("2.0.0", result.stderr)
        self.assertIn("1.0.0", result.stderr)
        self.assertFalse(
            output.exists(), "aucun fichier ne doit être écrit en cas de refus"
        )

    def test_a_tag_that_is_not_a_version_is_refused(self) -> None:
        output = self.directory / "altstore.json"
        result = run_script(
            self.ipa, output, self.entitlements, tag="release-finale", check_tag=True
        )
        self.assertEqual(result.returncode, 1)

    def test_a_missing_entitlements_file_is_refused(self) -> None:
        output = self.directory / "altstore.json"
        result = run_script(
            self.ipa, output, [self.directory / "inexistant.entitlements"]
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("inexistant", result.stderr)

    def test_an_ipa_without_info_plist_is_refused(self) -> None:
        broken = self.directory / "vide.ipa"
        with zipfile.ZipFile(broken, "w") as archive:
            archive.writestr("Payload/Vocabulle.app/vide", b"")
        result = run_script(broken, self.directory / "altstore.json", self.entitlements)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Info.plist", result.stderr)

    def test_an_ipa_without_version_is_refused(self) -> None:
        broken = self.directory / "sans-version.ipa"
        with zipfile.ZipFile(broken, "w") as archive:
            archive.writestr(
                "Payload/Vocabulle.app/Info.plist",
                plistlib.dumps(
                    {"CFBundleIdentifier": APP_IDENTIFIER}, fmt=plistlib.FMT_BINARY
                ),
            )
        result = run_script(broken, self.directory / "altstore.json", self.entitlements)
        self.assertEqual(result.returncode, 1)
        self.assertIn("CFBundleShortVersionString", result.stderr)


class RealEntitlementsTests(unittest.TestCase):
    """Les entitlements livrés dans le dépôt sont ceux que la source déclarera.

    Ce test relie la source à la réalité du projet : si un entitlement est
    ajouté à l'application ou à l'extension sans que la source le sache,
    AltStore refusera l'installation — et rien d'autre ne le signalerait.
    """

    def test_the_shipped_entitlements_declare_the_shared_group(self) -> None:
        for path in REAL_ENTITLEMENTS:
            with self.subTest(fichier=path.name):
                self.assertTrue(path.is_file(), f"{path} est absent du dépôt")
                payload = plistlib.loads(path.read_bytes())
                self.assertEqual(
                    payload.get("com.apple.security.application-groups"), [APP_GROUP]
                )

    def test_the_generated_source_declares_exactly_the_shipped_entitlements(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            ipa = write_ipa(directory)
            output = directory / "altstore.json"
            result = run_script(ipa, output, list(REAL_ENTITLEMENTS))
            self.assertEqual(result.returncode, 0, result.stderr)
            source = json.loads(output.read_text(encoding="utf-8"))
            declared = source["apps"][0]["appPermissions"]["entitlements"]
            self.assertEqual(declared, ["com.apple.security.application-groups"])


if __name__ == "__main__":
    unittest.main()
