"""Contrôles structurels portables. Ne remplacent ni la compilation ni les tests.

Ces vérifications tournent partout, y compris sur une machine sans Xcode. Elles
attrapent la classe d'erreurs la plus coûteuse du projet : un fichier source qui
existe mais que le projet Xcode ignore silencieusement, une référence PBX
cassée, ou une extension widget retirée du projet — cette dernière étant la
façon la plus tentante et la plus destructrice de faire passer un build.
"""
from pathlib import Path
import json
import plistlib
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
APP_NAME = "Vocabulle"
WIDGET_NAME = "VocabulleWidget"
CORPUS_PATH = "Resources/vocabulle-corpus.sqlite"

failures = []


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def pbx_objects(project: str) -> dict:
    """Associe chaque identifiant PBX au corps de l'objet qu'il définit."""
    objects = {}
    for line in project.splitlines():
        stripped = line.strip()
        identifier, separator, body = stripped.partition(" = ")
        if not separator or not re.fullmatch(r"[A-F0-9]{24}", identifier):
            continue
        objects[identifier] = body
    return objects


def target_files(project: str, phase_isa: str = "PBXSourcesBuildPhase") -> dict:
    """Pour chaque chemin de fichier, l'ensemble des cibles qui le compilent.

    On suit le graphe réel — cible → phase de compilation → entrée de
    compilation → référence de fichier — au lieu de compter les occurrences du
    chemin dans le texte du projet. Compter les occurrences confondait « le
    fichier est référencé deux fois » avec « le fichier est compilé par deux
    cibles » : la première situation est un projet invalide, la seconde est
    l'exigence du cahier des charges.
    """
    objects = pbx_objects(project)

    references = {}
    build_files = {}
    for identifier, body in objects.items():
        if "isa = PBXFileReference" in body:
            path = re.search(r'path = "([^"]+)";', body)
            if path:
                references[identifier] = path.group(1)
        elif "isa = PBXBuildFile" in body:
            file_ref = re.search(r"fileRef = ([A-F0-9]{24});", body)
            if file_ref:
                build_files[identifier] = file_ref.group(1)

    sources_phases = {
        identifier: set(re.findall(r"[A-F0-9]{24}", body))
        for identifier, body in objects.items()
        if f"isa = {phase_isa}" in body
    }

    result = {}
    for body in objects.values():
        if "isa = PBXNativeTarget" not in body:
            continue
        name = re.search(r"; name = ([^;]+);", body)
        phases = re.search(r"buildPhases = \(([^)]*)\);", body)
        if not name or not phases:
            continue
        # `buildPhases` désigne des phases, pas des entrées de compilation : il
        # faut redescendre par `PBXSourcesBuildPhase.files` pour atteindre les
        # fichiers réellement compilés.
        files = set()
        for phase_id in re.findall(r"[A-F0-9]{24}", phases.group(1)):
            files |= sources_phases.get(phase_id, set())
        for build_id in files:
            file_ref = build_files.get(build_id)
            path = references.get(file_ref) if file_ref else None
            if path:
                result.setdefault(path, set()).add(name.group(1))
    return result


def main() -> int:
    pbxproj = ROOT / f"{APP_NAME}.xcodeproj" / "project.pbxproj"
    check(pbxproj.is_file(), f"Projet Xcode absent : {pbxproj.relative_to(ROOT)} — lancer scripts/generate_project.py")
    if not pbxproj.is_file():
        return report()

    project = pbxproj.read_text(encoding="utf-8")

    # 1. Intégrité du graphe d'objets PBX.
    definitions = re.findall(r"^\s*([A-F0-9]{24}) =", project, re.M)
    check(len(definitions) == len(set(definitions)), "Identifiants PBX dupliqués")
    references = set(re.findall(r"\b[A-F0-9]{24}\b", project))
    unresolved = references - set(definitions)
    check(not unresolved, f"Références PBX non résolues : {sorted(unresolved)[:5]}")

    # 2. Tout chemin déclaré existe réellement sur le disque.
    for path in re.findall(r'path = "([^"]+)";', project):
        if path.startswith("$"):
            continue
        check((ROOT / path).exists(), f"Fichier déclaré introuvable : {path}")

    # 3. Aucun fichier source oublié hors du projet Xcode.
    for folder in ["App", "Core", "Shared", "Widget"]:
        for path in (ROOT / folder).rglob("*.swift"):
            name = path.relative_to(ROOT).as_posix()
            check(name in project, f"Source absente du projet Xcode : {name}")

    # Core/ et Shared/ doivent être compilés par les DEUX cibles : c'est la
    # garantie que l'application et l'extension exécutent littéralement le même
    # moteur de sélection. Une seule cible signalerait une divergence silencieuse
    # entre le terme de l'écran verrouillé et celui de l'application.
    #
    # La règle couvre aussi Shared/ depuis une panne réelle : le thème vivait
    # dans App/, le widget le référençait, et rien ne l'a signalé avant que
    # xcodebuild ne s'en aperçoive — après le push, sur le seul compilateur
    # disponible. Un fichier partagé rangé dans une seule cible est exactement
    # ce que ce contrôle doit rendre impossible.
    compiled = target_files(project)
    for folder in ["Core", "Shared"]:
        for path in (ROOT / folder).rglob("*.swift"):
            name = path.relative_to(ROOT).as_posix()
            targets = compiled.get(name, set())
            check({APP_NAME, WIDGET_NAME} <= targets,
                  f"{name} n'est pas compilé à la fois dans l'application et dans l'extension "
                  f"(cibles : {sorted(targets) or 'aucune'})")

    # Le corpus doit être copié dans les DEUX bundles. Dans un seul, l'autre
    # cible ouvrirait une base absente et afficherait « corpus inaccessible » —
    # une panne qui ne se voit qu'à l'installation, sur l'écran verrouillé.
    resources = target_files(project, "PBXResourcesBuildPhase")
    for path in [CORPUS_PATH]:
        names = resources.get(path, set())
        check({APP_NAME, WIDGET_NAME} <= names,
              f"{path} n'est pas copié dans les ressources de l'application ET de "
              f"l'extension (cibles : {sorted(names) or 'aucune'})")

    # L'icône absente est un défaut silencieux : sans elle, tout compile,
    # l'archive se fabrique, l'IPA s'installe — et l'application apparaît avec
    # une icône blanche sur l'écran d'accueil. Ni Xcode ni l'empaqueteur ne
    # s'en plaignent, et rien d'autre dans cette validation ne le verrait. Ce
    # contrôle existe parce que le dépôt a réellement été livré ainsi : le jeu
    # d'icônes déclarait un emplacement, sans nommer de fichier.
    icon_set = ROOT / "App" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
    manifest = icon_set / "Contents.json"
    if manifest.is_file():
        images = json.loads(manifest.read_text(encoding="utf-8")).get("images", [])
        named = [image for image in images if image.get("filename")]
        check(bool(named),
              "AppIcon.appiconset ne référence aucun fichier : l'application serait "
              "construite avec une icône blanche, sans que rien ne le signale")
        for image in named:
            check((icon_set / image["filename"]).is_file(),
                  f"Icône déclarée mais absente du dépôt : {image['filename']}")
    else:
        check(False, "AppIcon.appiconset/Contents.json est absent")

    for path in (ROOT / "Tests" / "iOS").rglob("*.swift"):
        name = path.relative_to(ROOT).as_posix()
        check(name in project, f"Test iOS absent du projet : {name}")

    # 4. Les tests SwiftPM ne doivent PAS entrer dans le projet Xcode : ils
    #    importent le module VocabulleCore, qui n'existe que pour SwiftPM.
    for path in (ROOT / "Tests" / "Core").rglob("*.swift"):
        name = path.relative_to(ROOT).as_posix()
        check(name not in project, f"Test SwiftPM compilé par erreur dans la cible XCTest : {name}")

    # 5. L'extension widget doit être présente, embarquée dans PlugIns.
    check(f"{WIDGET_NAME}.appex" in project, "L'extension widget a disparu du projet Xcode")
    check("dstSubfolderSpec = 13" in project, "Aucune phase de copie vers PlugIns : le widget ne serait pas embarqué")
    check("com.apple.product-type.app-extension" in project, "La cible widget n'est plus une extension d'application")

    # 6. Tous les fichiers de configuration doivent être lisibles.
    for path in list(ROOT.rglob("*.plist")) + list(ROOT.rglob("*.xcprivacy")):
        if ".git" in path.parts:
            continue
        try:
            with path.open("rb") as handle:
                plistlib.load(handle)
        except Exception as error:  # noqa: BLE001 — on veut le nom du fichier fautif
            failures.append(f"Fichier de configuration illisible : {path.relative_to(ROOT)} ({error})")

    for path in (ROOT / "App" / "Resources").rglob("*.json"):
        try:
            json.loads(path.read_text(encoding="utf-8"))
        except Exception as error:  # noqa: BLE001
            failures.append(f"JSON invalide : {path.relative_to(ROOT)} ({error})")

    # 7. Le manifeste de confidentialité doit exister côté application ET côté
    #    extension : Apple l'exige pour chaque bundle déposé.
    check((ROOT / "App" / "Resources" / "PrivacyInfo.xcprivacy").is_file(), "PrivacyInfo.xcprivacy absent de l'application")
    check((ROOT / "Widget" / "Resources" / "PrivacyInfo.xcprivacy").is_file(), "PrivacyInfo.xcprivacy absent de l'extension")

    # 8. Le schéma et l'espace de travail doivent être du XML valide.
    for path in [ROOT / f"{APP_NAME}.xcodeproj" / "xcshareddata" / "xcschemes" / f"{APP_NAME}.xcscheme",
                 ROOT / f"{APP_NAME}.xcodeproj" / "project.xcworkspace" / "contents.xcworkspacedata"]:
        try:
            ET.parse(path)
        except Exception as error:  # noqa: BLE001
            failures.append(f"XML invalide : {path.relative_to(ROOT)} ({error})")

    # 9. Points de contrôle du contenu des Info.plist.
    app_info_path = ROOT / "App" / "Resources" / "Info.plist"
    if app_info_path.is_file():
        with app_info_path.open("rb") as handle:
            info = plistlib.load(handle)
        check(info.get("CFBundleDisplayName") == "Vocabulle", "CFBundleDisplayName doit valoir « Vocabulle »")
        check(info.get("UILaunchScreen") is not None, "UILaunchScreen manquant : l'application serait affichée en format réduit")
        check("fr" in info.get("CFBundleLocalizations", []), "La localisation française doit être déclarée")
        check("NSUserTrackingUsageDescription" not in info, "Aucun suivi ne doit être déclaré : le projet n'embarque ni analyse ni publicité")
        check("UIBackgroundModes" not in info, "Aucun mode d'arrière-plan n'est justifié")

    widget_info_path = ROOT / "Widget" / "Resources" / "Info.plist"
    if widget_info_path.is_file():
        with widget_info_path.open("rb") as handle:
            info = plistlib.load(handle)
        extension = info.get("NSExtension", {})
        check(extension.get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension",
              "L'extension doit être déclarée comme widget WidgetKit")
        # WidgetKit n'a pas de classe principale : `@main` sur le WidgetBundle
        # fournit le point d'entrée. Apple refuse explicitement ces deux clés
        # pour le point d'extension com.apple.widgetkit-extension — « defines a
        # principal class which is not allowed for the extension point » à
        # l'installation, « NSExtensionPrincipalClass is unexpected » au dépôt
        # sur l'App Store. Les exiger produirait la panne qu'on veut éviter.
        check("NSExtensionPrincipalClass" not in extension,
              "NSExtensionPrincipalClass n'est pas autorisé pour une extension WidgetKit")
        check("NSExtensionMainStoryboard" not in extension,
              "NSExtensionMainStoryboard n'est pas autorisé pour une extension WidgetKit")

    # 10. Compter les tests réellement écrits (ils ne sont pas exécutés ici).
    swiftpm_tests = sum(len(re.findall(r"func test\w+\(", p.read_text(encoding="utf-8")))
                        for p in (ROOT / "Tests" / "Core").rglob("*.swift"))
    ios_tests = sum(len(re.findall(r"func test\w+\(", p.read_text(encoding="utf-8")))
                    for p in (ROOT / "Tests" / "iOS").rglob("*.swift"))
    print(f"Tests déclarés : {swiftpm_tests} SwiftPM (swift test) + {ios_tests} XCTest iOS (xcodebuild test).")
    return report()


def report() -> int:
    if failures:
        for message in failures:
            print(f"ÉCHEC : {message}")
        print(f"{len(failures)} problème(s) de structure détecté(s).")
        return 1
    print("Structure conforme : projet Xcode, sources, extension widget, Info.plist, manifestes et schéma.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
