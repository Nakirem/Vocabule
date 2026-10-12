import Foundation

/// Hachage stable, indépendant du processus et de la version du compilateur.
///
/// Swift réinitialise l'amorce de `Hasher` à chaque lancement : `hashValue`
/// change d'une exécution à l'autre. L'utiliser comme graine de sélection
/// donnerait un terme différent à chaque ouverture de l'application, et un
/// terme différent entre l'application et l'extension widget. Les fonctions
/// ci-dessous sont, elles, entièrement spécifiées : mêmes entrées, même sortie,
/// sur n'importe quelle machine et pour toujours.
public enum StableHash {
    /// FNV-1a 64 bits.
    public static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// Mélange d'un entier 64 bits (SplitMix64).
    public static func splitMix64(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    /// Combine plusieurs composantes en une graine unique. L'ordre compte.
    public static func combine(_ parts: [String]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for part in parts {
            for byte in part.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
            // Séparateur : sans lui, ["ab","c"] et ["a","bc"] seraient identiques.
            hash ^= 0x1f
            hash = hash &* prime
        }
        return splitMix64(hash)
    }
}

/// Générateur pseudo-aléatoire reproductible.
///
/// Ce n'est **pas** un générateur cryptographique et il ne doit jamais servir à
/// autre chose qu'à choisir un terme dans une liste triée. Sa vertu est d'être
/// reproductible : la même graine produit la même suite, aujourd'hui comme dans
/// deux ans.
public struct StableRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    /// Construit un générateur à partir de composantes textuelles.
    public init(seedParts: [String]) {
        self.state = StableHash.combine(seedParts)
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    /// Entier uniforme dans `0..<upperBound`, sans biais de repliement.
    public mutating func nextInt(upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        let bound = UInt64(upperBound)
        let limit = UInt64.max - (UInt64.max % bound)
        var draw = next()
        while draw >= limit {
            draw = next()
        }
        return Int(draw % bound)
    }
}
