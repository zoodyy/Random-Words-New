import Foundation

/// Simple mode trades choosing word lists for a single "Word complexity"
/// slider. The random words all come from the bundled 333k list, which runs
/// from the most common words to the rarest, and each level of the slider
/// stands for a stretch of it. Favouriting is switched off meanwhile.
///
/// The lists and ranges picked outside simple mode are left as they are, so
/// turning it off brings them straight back.
enum SimpleMode {

    static let storageKey = "simpleMode"
    static let levelStorageKey = "simpleModeComplexityLevel"

    static let wordlist = "333kwordlist-cleaned"

    static let levels = 1...10
    static let defaultLevel = 5

    /// Each level's part of the list, as fractions of its length. Neighbouring
    /// levels overlap, and the parts widen towards the rare end, where the
    /// words change less from one percent of the list to the next.
    private static let ranges: [(lower: Double, upper: Double)] = [
        (0.00, 0.03),  // 1: her, road, heart
        (0.01, 0.06),  // 2: appears, explain, nurse
        (0.03, 0.10),  // 3: valuable, crucial, thunder
        (0.06, 0.15),  // 4: livestock, gentleman, outdated
        (0.10, 0.22),  // 5: preparedness, captive, octopus
        (0.15, 0.32),  // 6: imaginative, anguish, resurgence
        (0.22, 0.45),  // 7: gloom, allegory, exegesis
        (0.32, 0.60),  // 8: chuckled, empathetic, heterogenous
        (0.45, 0.80),  // 9: purred, tahini, gunwale
        (0.60, 1.00),  // 10: extricated, trireme, oafish
    ]

    static func range(forLevel level: Int) -> (lower: Double, upper: Double) {
        ranges[min(max(level, levels.lowerBound), levels.upperBound) - 1]
    }
}
