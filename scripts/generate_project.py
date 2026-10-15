"""Fabrique Vocabulle.xcodeproj avec la seule bibliothèque standard de Python.

Aucune dépendance à XcodeGen ni à un Mac : le fichier projet est écrit à la
main, ce qui permet de le régénérer à l'identique en local comme en CI.

Trois cibles :

- ``Vocabulle``          l'application (``App/`` + ``Shared/`` + ``Core/``)
- ``VocabulleWidget``    l'extension widget (``Widget/`` + ``Shared/`` + ``Core/``)
- ``VocabulleTests``     tests XCTest hébergés par l'application (``Tests/iOS/``)

``Core/`` et ``Shared/`` sont compilés dans les deux premières. C'est
volontaire : l'application et l'extension exécutent alors littéralement le même
code de sélection, ce que le cahier des charges exige. Dupliquer la logique dans
deux cibles distinctes serait le seul moyen d'obtenir deux tirages divergents.

Ce qui sépare les deux tient à UIKit. ``Shared/`` contient ce qui en a besoin —
le thème, qui peint l'application comme l'écran verrouillé — et ``Core/`` reste
du Foundation pur, compilable par ``swift test`` sur macOS, où UIKit n'existe
pas. Ranger le thème dans ``Core/`` obligerait à le harnacher de ``#if`` ; le
laisser dans ``App/`` l'a rendu invisible au widget, ce qui a cassé la
compilation. ``Shared/`` est la troisième possibilité.

Les tests SwiftPM de ``Tests/Core/`` sont délibérément absents de ce projet :
ils font ``import VocabulleCore``, un module qui n'existe que pour SwiftPM, et
les inclure ici casserait la compilation de la cible XCTest.
"""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Vocabulle.xcodeproj"

APP_NAME = "Vocabulle"
WIDGET_NAME = "VocabulleWidget"
TESTS_NAME = "VocabulleTests"

BUNDLE_ID = "fr.vocabulle.app"
WIDGET_BUNDLE_ID = "fr.vocabulle.app.widget"

#: Corpus embarqué, dans les ressources des deux cibles.
CORPUS_PATH = "Resources/vocabulle-corpus.sqlite"


def uid(name: str) -> str:
    """Identifiant d'objet PBX stable, dérivé du nom.

    Stable est le mot important : régénérer le projet ne doit pas réécrire tous
    les identifiants, sinon chaque régénération produit un diff illisible et
    casse les références croisées de Xcode.
    """
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def quote(value) -> str:
    return json.dumps(str(value), ensure_ascii=False)


def relative(paths) -> list:
    return sorted(p.relative_to(ROOT).as_posix() for p in paths)


def run() -> None:
    app_files = relative(list((ROOT / "App").rglob("*.swift")))
    core_files = relative(list((ROOT / "Core").rglob("*.swift")))
    shared_files = relative(list((ROOT / "Shared").rglob("*.swift")))
    widget_files = relative(list((ROOT / "Widget").rglob("*.swift")))
    test_files = relative(list((ROOT / "Tests" / "iOS").rglob("*.swift")))

    # Ressources compilées (catalogues d'assets, manifestes de confidentialité).
    #
    # Le corpus est copié dans les DEUX bundles, et c'est un choix mesuré : il
    # pèse 3,4 Mo, soit 6,8 Mo au total, très loin du plafond de 100 Mo. La
    # solution économe — ne le mettre que dans l'application et le faire lire
    # par l'extension depuis un conteneur partagé — ne fonctionne pas ici : un
    # profil de compte Apple gratuit ne porte pas l'entitlement de groupe, et le
    # widget se retrouverait sans corpus au moment précis où il doit afficher un
    # mot. Un corpus dupliqué coûte des mégaoctets ; un widget vide coûte
    # l'application.
    app_resources = [
        "App/Resources/Assets.xcassets",
        "App/Resources/PrivacyInfo.xcprivacy",
        CORPUS_PATH,
    ]
    widget_resources = ["Widget/Resources/PrivacyInfo.xcprivacy", CORPUS_PATH]
    # Fichiers seulement référencés : l'Info.plist et les entitlements sont
    # consommés via des réglages de build, jamais copiés dans le bundle.
    extras = [
        "App/Resources/Info.plist",
        "App/Resources/Vocabulle.entitlements",
        "Widget/Resources/Info.plist",
        "Widget/Resources/VocabulleWidget.entitlements",
    ]

    objects = []

    def add(key: str, body: str) -> None:
        objects.append(f"\t\t{uid(key)} = {{ {body} }};")

    def refs(values) -> str:
        return "(" + ", ".join(uid(v) for v in values) + ("," if values else "") + ")"

    def filetype(path: str) -> str:
        if path.endswith(".swift"):
            return "sourcecode.swift"
        if path.endswith(".xcassets"):
            return "folder.assetcatalog"
        if path.endswith(".sqlite"):
            # Ressource opaque : Xcode la copie telle quelle, sans tenter de
            # l'ouvrir ni de la compiler.
            return "file"
        return "text.plist.xml"

    sources = {
        "app": app_files + shared_files + core_files,
        "widget": widget_files + shared_files + core_files,
        "test": test_files,
    }
    resources = {"app": app_resources, "widget": widget_resources, "test": []}

    # Déduplication obligatoire : les fichiers de `Core/` appartiennent à
    # l'application ET à l'extension, donc ils apparaissent deux fois dans la
    # liste. Sans ce filtre, chacun produirait deux `PBXFileReference` portant
    # le même identifiant, et Xcode refuserait d'ouvrir le projet.
    declared = []
    seen = set()
    for path in sources["app"] + sources["widget"] + sources["test"] + app_resources + widget_resources + extras:
        if path in seen:
            continue
        seen.add(path)
        declared.append(path)
    for path in declared:
        add("ref:" + path, f"isa = PBXFileReference; lastKnownFileType = {quote(filetype(path))}; path = {quote(path)}; sourceTree = SOURCE_ROOT;")

    # Les identifiants de build sont nommés par cible : un même fichier de Core/
    # appartient à l'application ET à l'extension, et deux PBXBuildFile ne
    # peuvent pas partager le même identifiant.
    for target, files in sources.items():
        for path in files:
            add(f"build:{target}:{path}", f"isa = PBXBuildFile; fileRef = {uid('ref:' + path)};")
    for path in app_resources:
        add(f"build:app:{path}", f"isa = PBXBuildFile; fileRef = {uid('ref:' + path)};")
    for path in widget_resources:
        add(f"build:widget:{path}", f"isa = PBXBuildFile; fileRef = {uid('ref:' + path)};")

    add("app-product", f"isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {APP_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR;")
    add("widget-product", f"isa = PBXFileReference; explicitFileType = \"wrapper.app-extension\"; includeInIndex = 0; path = {WIDGET_NAME}.appex; sourceTree = BUILT_PRODUCTS_DIR;")
    add("test-product", f"isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = {TESTS_NAME}.xctest; sourceTree = BUILT_PRODUCTS_DIR;")

    def group(name: str, children) -> None:
        add(f"group:{name}", f"isa = PBXGroup; name = {quote(name)}; children = {refs(children)}; sourceTree = \"<group>\";")

    group("root", ["group:App", "group:Core", "group:Widget", "group:Tests", "group:Resources", "group:Products"])
    group("App", ["ref:" + p for p in app_files])
    group("Core", ["ref:" + p for p in core_files])
    group("Widget", ["ref:" + p for p in widget_files])
    group("Tests", ["ref:" + p for p in test_files])
    # Le corpus appartient aux deux cibles, donc il apparaît deux fois dans les
    # listes de ressources : sans déduplication, le groupe le référencerait deux
    # fois et Xcode afficherait un doublon.
    group("Resources", ["ref:" + p for p in dict.fromkeys(app_resources + widget_resources + extras)])
    group("Products", ["app-product", "widget-product", "test-product"])

    for target, files in sources.items():
        add(f"{target}-sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs([f'build:{target}:{p}' for p in files])}; runOnlyForDeploymentPostprocessing = 0;")
        add(f"{target}-frameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
        add(f"{target}-resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {refs([f'build:{target}:{p}' for p in resources[target]])}; runOnlyForDeploymentPostprocessing = 0;")

    # Copie de l'extension dans Vocabulle.app/PlugIns (dstSubfolderSpec = 13).
    # C'est cette phase qui fait exister le widget dans l'IPA ; sans elle,
    # l'archive contiendrait une application sans écran verrouillé.
    add("build:embed:widget", f"isa = PBXBuildFile; fileRef = {uid('widget-product')}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }};")
    add("embed-widget", f"isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 13; files = {refs(['build:embed:widget'])}; name = \"Embed App Extensions\"; runOnlyForDeploymentPostprocessing = 0;")

    add("proxy-widget", f"isa = PBXContainerItemProxy; containerPortal = {uid('project')}; proxyType = 1; remoteGlobalIDString = {uid('widget-target')}; remoteInfo = {WIDGET_NAME};")
    add("dependency-widget", f"isa = PBXTargetDependency; target = {uid('widget-target')}; targetProxy = {uid('proxy-widget')};")
    add("proxy-test", f"isa = PBXContainerItemProxy; containerPortal = {uid('project')}; proxyType = 1; remoteGlobalIDString = {uid('app-target')}; remoteInfo = {APP_NAME};")
    add("dependency-test", f"isa = PBXTargetDependency; target = {uid('app-target')}; targetProxy = {uid('proxy-test')};")

    targets = [
        ("app", APP_NAME, "application", ["app-sources", "app-frameworks", "app-resources", "embed-widget"], ["dependency-widget"]),
        ("widget", WIDGET_NAME, "app-extension", ["widget-sources", "widget-frameworks", "widget-resources"], []),
        ("test", TESTS_NAME, "bundle.unit-test", ["test-sources", "test-frameworks", "test-resources"], ["dependency-test"]),
    ]
    for key, name, producttype, phases, deps in targets:
        add(f"{key}-target", f"isa = PBXNativeTarget; buildConfigurationList = {uid(key + '-configs')}; buildPhases = {refs(phases)}; buildRules = (); dependencies = {refs(deps)}; name = {name}; productName = {name}; productReference = {uid(key + '-product')}; productType = {quote('com.apple.product-type.' + producttype)};")

    project_settings = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "GCC_WARN_UNUSED_FUNCTION": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        # iOS 17 est le plancher réel : Button(intent:) dans un widget d'écran
        # verrouillé n'existe pas avant. On ne déclare aucune API iOS 27.
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0",
        "SWIFT_STRICT_CONCURRENCY": "targeted",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "DEVELOPMENT_LANGUAGE": "fr",
    }
    app_settings = {
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "INFOPLIST_FILE": "App/Resources/Info.plist",
        "GENERATE_INFOPLIST_FILE": "NO",
        "CODE_SIGN_ENTITLEMENTS": "App/Resources/Vocabulle.entitlements",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "MARKETING_VERSION": "1.2",
        "TARGETED_DEVICE_FAMILY": "1",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SUPPORTS_MACCATALYST": "NO",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
    }
    widget_settings = {
        "PRODUCT_BUNDLE_IDENTIFIER": WIDGET_BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "INFOPLIST_FILE": "Widget/Resources/Info.plist",
        "GENERATE_INFOPLIST_FILE": "NO",
        "CODE_SIGN_ENTITLEMENTS": "Widget/Resources/VocabulleWidget.entitlements",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "MARKETING_VERSION": "1.2",
        "TARGETED_DEVICE_FAMILY": "1",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        # Une extension ne s'installe pas seule et n'a pas le droit d'appeler
        # les API réservées aux applications.
        "SKIP_INSTALL": "YES",
        "APPLICATION_EXTENSION_API_ONLY": "YES",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
    }
    test_settings = {
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID + ".tests",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "GENERATE_INFOPLIST_FILE": "YES",
        "CODE_SIGN_STYLE": "Automatic",
        "TARGETED_DEVICE_FAMILY": "1",
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "TEST_HOST": f"$(BUILT_PRODUCTS_DIR)/{APP_NAME}.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/{APP_NAME}",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @loader_path/Frameworks",
    }

    for scope, base in [("project", project_settings), ("app", app_settings), ("widget", widget_settings), ("test", test_settings)]:
        for name in ["Debug", "Release"]:
            settings = dict(base)
            if scope == "project":
                settings.update({
                    "DEBUG_INFORMATION_FORMAT": "dwarf" if name == "Debug" else "dwarf-with-dsym",
                    "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if name == "Debug" else "-O",
                    "SWIFT_COMPILATION_MODE": "singlefile" if name == "Debug" else "wholemodule",
                    "ENABLE_NS_ASSERTIONS": "YES" if name == "Debug" else "NO",
                })
                if name == "Debug":
                    settings.update({
                        "ENABLE_TESTABILITY": "YES",
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
                        "ONLY_ACTIVE_ARCH": "YES",
                    })
            body = " ".join(f"{key} = {quote(value)};" for key, value in settings.items())
            add(f"{scope}-{name}", f"isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {name};")
        add(f"{scope}-configs", f"isa = XCConfigurationList; buildConfigurations = {refs([scope + '-Debug', scope + '-Release'])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")

    add("project", f"isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; TargetAttributes = {{ {uid('app-target')} = {{ CreatedOnToolsVersion = 16.0; }}; {uid('widget-target')} = {{ CreatedOnToolsVersion = 16.0; }}; {uid('test-target')} = {{ CreatedOnToolsVersion = 16.0; TestTargetID = {uid('app-target')}; }}; }}; }}; buildConfigurationList = {uid('project-configs')}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = fr; hasScannedForEncodings = 0; knownRegions = (fr, en, Base); mainGroup = {uid('group:root')}; productRefGroup = {uid('group:Products')}; projectDirPath = \"\"; projectRoot = \"\"; targets = {refs(['app-target', 'widget-target', 'test-target'])};")

    PROJECT.mkdir(exist_ok=True)
    (PROJECT / "project.pbxproj").write_text(
        "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n"
        + "\n".join(objects)
        + f"\n\t}};\n\trootObject = {uid('project')};\n}}\n",
        encoding="utf-8",
    )

    schemes = PROJECT / "xcshareddata" / "xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    container = f"container:{APP_NAME}.xcodeproj"

    def buildable(key: str, name: str, suffix: str) -> str:
        return (f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(key)}" '
                f'BuildableName="{name}{suffix}" BlueprintName="{name}" ReferencedContainer="{container}"/>')

    app_ref = buildable("app-target", APP_NAME, ".app")
    test_ref = buildable("test-target", TESTS_NAME, ".xctest")
    (schemes / f"{APP_NAME}.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''', encoding="utf-8")

    workspace = PROJECT / "project.xcworkspace"
    workspace.mkdir(exist_ok=True)
    (workspace / "contents.xcworkspacedata").write_text(
        '<?xml version="1.0" encoding="UTF-8"?><Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>\n',
        encoding="utf-8",
    )
    print(
        f"Projet Xcode régénéré : {len(app_files)} fichiers d'application, "
        f"{len(core_files)} fichiers de logique partagée, "
        f"{len(shared_files)} fichiers partagés hors logique, "
        f"{len(widget_files)} fichiers de widget, {len(test_files)} fichiers de test iOS."
    )


if __name__ == "__main__":
    run()
