import Foundation

/// Normalisation du texte pour la recherche.
///
/// La même normalisation doit être appliquée **des deux côtés** : la chaîne de
/// production l'applique au terme et à la définition avant de les écrire dans la
/// colonne `search_text`, et le moteur l'applique à la requête de l'utilisateur.
/// Si les deux diffèrent, « ephemere » ne trouve plus « éphémère » — et c'est
/// exactement ce que la recherche doit garantir.
///
/// La contrepartie Python (`tools/corpus/normalize.py`) implémente la même
/// règle : décomposition Unicode, suppression des diacritiques, minuscules,
/// espaces réduits. Une divergence entre les deux se voit immédiatement dans
/// `scripts/validate_corpus.py`, qui compare les deux implémentations sur un
/// échantillon.
public enum SearchNormalizer {

    /// Forme canonique utilisée pour l'indexation et pour les requêtes.
    ///
    /// - Décompose puis retire les marques diacritiques (`é` → `e`, `ç` → `c`).
    /// - Passe en minuscules.
    /// - Remplace toute ponctuation par une espace.
    /// - Réduit les espaces multiples et rogne les extrémités.
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "fr_FR")
        )

        var out = ""
        out.reserveCapacity(folded.count)
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Découpe une requête en mots normalisés non vides.
    ///
    /// Une recherche multi-mots exige que **tous** les mots soient présents :
    /// « victoire pyrrhus » doit trouver « victoire à la Pyrrhus ».
    public static func terms(in query: String) -> [String] {
        normalize(query).split(separator: " ").map(String.init)
    }
}
