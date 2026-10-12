"""Tests de l'empaquetage IPA.

# Pourquoi ces tests comptent plus qu'ils n'en ont l'air

``package_ipa.py`` est le dernier maillon avant l'installation. Une erreur ici
ne se voit pas en CI : elle se voit sur le téléphone, sous la forme d'une
installation qui échoue ou d'une application qui s'ouvre sans son widget. Les
refus qu'on teste sont donc ceux qui protègent l'utilisateur, pas des cas
théoriques.

Écrits en ``unittest`` de la bibliothèque standard : la CI les lance avec
``python3 -m unittest discover`` et ils tournent aussi sous pytest sans
adaptation.
"""
from __future__ import annotations

import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "package_ipa.py"

APP_IDENTIFIER = "fr.vocabulle.app"
WIDGET_IDENTIFIER = "fr.vocabulle.app.widget"


def write_app(
    directory: Path,
    *,
    identifier: str | None = APP_IDENTIFIER,
    include_extension: bool = True,
    platform: str = "iPhoneOS",
) -> Path:
    """Fabrique une application minimale, avec ou sans extension."""
    app = directory / "Vocabulle.app"
    (app / "PlugIns").mkdir(parents=True, exist_ok=True)

    # L'empaqueteur exige les DEUX clés : `DTPlatformName` seule ne suffit pas
    # à distinguer un build d'appareil d'un build de simulateur, et n'en fournir
    # qu'une fait échouer la détection — ce que ce test a révélé.
    info = {
        "CFBundleExecutable": "Vocabulle",
        "CFBundleIdentifier": identifier or "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleName": "Vocabulle",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "DTPlatformName": platform.lower(),
        "CFBundleSupportedPlatforms": [platform],
        "MinimumOSVersion": "17.0",
    }
    with (app / "Info.plist").open("wb") as handle:
        plistlib.dump(info, handle)
    (app / "Vocabulle").write_bytes(b"binaire")

    if include_extension:
        extension = app / "PlugIns" / "VocabulleWidget.appex"
        extension.mkdir(parents=True, exist_ok=True)
        extension_info = {
            "CFBundleExecutable": "VocabulleWidget",
            "CFBundleIdentifier": WIDGET_IDENTIFIER,
            "CFBundlePackageType": "XPC!",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"},
        }
        with (extension / "Info.plist").open("wb") as handle:
            plistlib.dump(extension_info, handle)
        (extension / "VocabulleWidget").write_bytes(b"binaire")

    return app


class PackageIPATests(unittest.TestCase):

    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="vocabulle-ipa-"))
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)

    def run_script(self, app: Path, output: Path | None = None, extra: list[str] | None = None):
        output = output or (self.directory / "Vocabulle.ipa")
        command = [
            sys.executable,
            str(SCRIPT),
            "--app", str(app),
            "--output", str(output),
            *(extra or []),
        ]
        return subprocess.run(command, capture_output=True, text=True), output

    # MARK: - Cas nominal

    def test_packages_an_app_with_its_extension(self) -> None:
        app = write_app(self.directory)
        result, output = self.run_script(app)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(output.is_file(), "L'IPA doit être produite")

        with zipfile.ZipFile(output) as archive:
            names = archive.namelist()
            self.assertIn("Payload/Vocabulle.app/Info.plist", names)
            self.assertIn(
                "Payload/Vocabulle.app/PlugIns/VocabulleWidget.appex/Info.plist",
                names,
                "Le widget doit être embarqué : sans lui, l'écran verrouillé reste vide",
            )
            # Les fichiers de métadonnées de macOS font échouer l'installation
            # sur l'appareil : ils ne doivent jamais entrer dans l'archive.
            unwanted = [name for name in names if name.startswith("__MACOSX") or "/._" in name]
            self.assertEqual(unwanted, [], f"Fichiers parasites dans l'IPA : {unwanted}")

    # MARK: - Refus qui protègent l'utilisateur

    def test_refuses_an_app_without_its_extension(self) -> None:
        # Le cahier des charges l'interdit explicitement : retirer l'extension
        # est la façon la plus tentante — et la plus destructrice — de faire
        # passer une compilation.
        app = write_app(self.directory, include_extension=False)
        result, output = self.run_script(app)

        self.assertNotEqual(result.returncode, 0, "Un build sans widget doit être refusé")
        self.assertFalse(output.exists())
        self.assertIn("widget", (result.stderr + result.stdout).lower())

    def test_allows_missing_extension_only_when_explicitly_asked(self) -> None:
        app = write_app(self.directory, include_extension=False)
        result, output = self.run_script(app, extra=["--allow-missing-extension"])

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(output.is_file())

    def test_refuses_an_unresolved_bundle_identifier(self) -> None:
        # Un identifiant resté sous forme de variable de build signifie que le
        # projet n'est pas correctement configuré : AltStore ne pourrait pas
        # re-signer l'application.
        app = write_app(self.directory, identifier=None)
        result, output = self.run_script(app)

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def test_refuses_a_simulator_build(self) -> None:
        # Un binaire de simulateur s'installe sans erreur apparente puis refuse
        # de se lancer : mieux vaut échouer à l'empaquetage.
        app = write_app(self.directory, platform="iPhoneSimulator")
        result, output = self.run_script(app)

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def test_refuses_a_simulator_build_detected_by_the_supported_platforms_only(self) -> None:
        """Le cas sournois : `DTPlatformName` correct, liste des plateformes fausse.

        Un build de simulateur dont seul `CFBundleSupportedPlatforms` trahit
        l'origine doit être refusé. Se fier à une seule des deux clés laisserait
        passer une IPA qui s'installe puis ne se lance pas.
        """
        app = write_app(self.directory)
        with (app / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        info["DTPlatformName"] = "iphoneos"
        info["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
        with (app / "Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)

        result, output = self.run_script(app)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def test_refuses_a_non_app_input(self) -> None:
        not_an_app = self.directory / "Vocabulle.txt"
        not_an_app.write_text("ceci n'est pas une application")
        result, _ = self.run_script(not_an_app)
        self.assertNotEqual(result.returncode, 0)

    def test_refuses_to_overwrite_an_existing_ipa(self) -> None:
        app = write_app(self.directory)
        output = self.directory / "Vocabulle.ipa"
        output.write_bytes(b"deja la")

        result, _ = self.run_script(app, output=output)
        self.assertNotEqual(result.returncode, 0, "Écraser une IPA existante doit être refusé")
        self.assertEqual(
            output.read_bytes(),
            b"deja la",
            "Le fichier existant ne doit pas être modifié",
        )

    def test_refuses_an_output_inside_the_app(self) -> None:
        app = write_app(self.directory)
        result, _ = self.run_script(app, output=app / "Vocabulle.ipa")
        self.assertNotEqual(
            result.returncode,
            0,
            "Une IPA écrite dans le bundle corromprait l'application",
        )

    def test_refuses_a_symlink_escaping_the_app(self) -> None:
        app = write_app(self.directory)
        outside = self.directory / "secret.txt"
        outside.write_text("hors du bundle")
        (app / "lien").symlink_to(outside)

        result, output = self.run_script(app)
        self.assertNotEqual(result.returncode, 0, "Un lien sortant doit être refusé")
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
