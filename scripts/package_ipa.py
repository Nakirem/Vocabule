"""Empaquette une application iPhone compilée par Xcode pour AltStore.

Ce script ne compile rien et ne signe rien. Il produit l'archive ``Payload/…``
qu'AltStore Classic re-signera sur l'iPhone avec le compte Apple de
l'utilisateur — un compte gratuit suffit.

Bibliothèque standard uniquement, et l'application d'entrée n'est jamais
modifiée.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import sys
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED

EXTENSION_SUFFIX = ".appex"


def package(app: Path, output: Path, require_extension: bool = True) -> Path:
    app = app.resolve()
    output = output.resolve()
    if not app.is_dir() or app.suffix != ".app":
        raise ValueError("Un dossier .app existant est attendu en entrée")
    if output.suffix != ".ipa" or output.is_relative_to(app):
        raise ValueError("La sortie doit être un .ipa situé hors de l'application d'entrée")
    if output.exists():
        raise ValueError("La sortie existe déjà ; choisir un autre chemin")

    with (app / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)

    # Un build de simulateur ne s'installe pas sur un iPhone. Le refuser ici
    # évite de livrer une IPA qui échouerait à l'installation sans explication.
    if info.get("DTPlatformName") != "iphoneos" or "iPhoneOS" not in info.get("CFBundleSupportedPlatforms", []):
        raise ValueError("Seul un build pour appareil iPhone est accepté, jamais un build de simulateur")

    executable = info.get("CFBundleExecutable", "")
    if not executable or Path(executable).name != executable or not (app / executable).is_file():
        raise ValueError("Exécutable d'application manquant ou invalide")

    identifier = info.get("CFBundleIdentifier", "")
    if not identifier or "$" in identifier:
        raise ValueError("Identifiant de bundle manquant ou non résolu")

    # L'extension widget est centrale : une IPA sans elle n'a pas d'écran
    # verrouillé. On refuse de produire une archive incomplète plutôt que de
    # laisser croire que le widget a été livré.
    plugins = app / "PlugIns"
    extensions = sorted(p.name for p in plugins.glob(f"*{EXTENSION_SUFFIX}")) if plugins.is_dir() else []
    if require_extension and not extensions:
        raise ValueError(
            "Aucune extension .appex dans PlugIns/ : le widget est absent du build. "
            "Ne jamais retirer l'extension pour faire passer la compilation."
        )

    # Tous les chemins sont inspectés avant d'écrire quoi que ce soit. Les liens
    # symboliques des frameworks sont préservés, mais aucun ne doit pointer hors
    # de l'application.
    files = sorted(path for path in app.rglob("*") if path.is_file() or path.is_symlink())
    for path in files:
        if path.is_symlink() and not path.resolve().is_relative_to(app):
            raise ValueError("Un lien symbolique pointe hors de l'application")

    output.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(output, "x", compression=ZIP_DEFLATED) as archive:
        for path in files:
            if path.name == ".DS_Store":
                continue
            name = "Payload/" + app.name + "/" + path.relative_to(app).as_posix()
            if path.is_symlink():
                # Entrée de lien symbolique Unix : sans create_system = 3 et le
                # bit S_IFLNK, l'archive contiendrait une copie du fichier et
                # les frameworks seraient refusés à l'installation.
                entry = ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(entry, os.readlink(path).encode("utf-8"))
            else:
                entry = ZipInfo.from_file(path, arcname=name)
                entry.create_system = 3
                mode = path.stat().st_mode
                if path == app / executable:
                    mode |= 0o111
                entry.external_attr = mode << 16
                archive.writestr(entry, path.read_bytes(), compress_type=ZIP_DEFLATED)

    with ZipFile(output) as archive:
        if archive.testzip() is not None:
            raise ValueError("L'archive générée a échoué au contrôle d'intégrité CRC")
        names = archive.namelist()
        if f"Payload/{app.name}/{executable}" not in names:
            raise ValueError("L'exécutable est absent de l'archive générée")
        if require_extension:
            for extension in extensions:
                expected = f"Payload/{app.name}/PlugIns/{extension}/"
                if not any(name.startswith(expected) for name in names):
                    raise ValueError(f"L'extension {extension} est absente de l'archive générée")
        if any(name.startswith("__MACOSX") or "/._" in name for name in names):
            raise ValueError("Entrées AppleDouble détectées : AltStore refuserait l'archive")

    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(".ipa.sha256").write_text(f"{digest}  {output.name}\n", encoding="utf-8")
    metadata = {
        "bundle_identifier": identifier,
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "minimum_ios": info.get("MinimumOSVersion"),
        "platform": "iphoneos",
        "app_extensions": extensions,
        "signing": "À re-signer par AltStore Classic avant installation",
        "commit": os.environ.get("GITHUB_SHA"),
        "sha256": digest,
    }
    output.with_suffix(".json").write_text(json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--allow-missing-extension",
        action="store_true",
        help="Autorise une IPA sans extension widget. Réservé aux essais de packaging, jamais à une livraison.",
    )
    args = parser.parse_args()
    try:
        result = package(args.app, args.output, require_extension=not args.allow_missing_extension)
    except ValueError as error:
        print(f"Empaquetage refusé : {error}", file=sys.stderr)
        return 1
    print(f"IPA prête pour AltStore : {result}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
