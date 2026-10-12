import SwiftUI
import WidgetKit

/// Point d'entrée de l'extension.
///
/// `@main` sur le `WidgetBundle` **est** le point d'entrée : c'est pour cela que
/// `NSExtensionPrincipalClass` ne figure pas dans `Widget/Resources/Info.plist`.
/// Apple refuse explicitement cette clé pour le point d'extension
/// `com.apple.widgetkit-extension`, et la déclarer empêcherait l'installation.
@main
struct VocabulleWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
    }
}
