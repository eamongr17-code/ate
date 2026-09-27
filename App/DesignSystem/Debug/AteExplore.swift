import Foundation

/// **Round 5 explorations** — each open visual question built both ways and picked from launch with
/// `-ate-r5-<item> A|B` (Debug and Beta only). No argument is today's behaviour. Each item is deleted,
/// with its losing variant, the moment Eamon picks.
enum AteExplore {
    /// `-ate-r5-photo A|B` — a tapped photo floating over the blurred page (A: the photo whole; B: a
    /// 4:5 card with its neighbours peeking).
    static var photo: String? { variant("photo") }
    /// `-ate-r5-diet A|B` — how the composer's Diet key opens its row of codes.
    static var diet: String? { variant("diet") }
    /// `-ate-r5-receipt A|B` — the share receipt led by the dishes, the place secondary.
    static var receipt: String? { variant("receipt") }
    /// `-ate-r5-dark A|B` — the dark palette: softened score yellow, recoloured keys and chips.
    static var dark: String? { variant("dark") }

    private static func variant(_ item: String) -> String? {
        #if DEBUG || BETA
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-ate-r5-\(item)"), arguments.indices.contains(index + 1)
        else { return nil }
        let value = arguments[index + 1].uppercased()
        return ["A", "B"].contains(value) ? value : nil
        #else
        return nil
        #endif
    }
}
