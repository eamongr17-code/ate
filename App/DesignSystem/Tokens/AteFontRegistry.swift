import CoreText
import UIKit

/// Finds the bundled font files and registers them with Core Text.
///
/// Registration happens lazily on first use rather than at app launch, so SwiftUI previews and the
/// debug gallery get the real fonts without depending on anything having run first.
final class AteFontRegistry: @unchecked Sendable {
    struct Face {
        let family: String
        private let regular: String
        /// Spectral is not variable: its medium is a separate file, chosen by weight.
        private let medium: String?
        let variationAxes: Set<Int>?
        let opticalSizeRange: ClosedRange<CGFloat>?
        /// The `wght` axis's own range. A style can ask for more (titles say 800, Radio Canada Big
        /// stops at 700), and the axis is pinned inside it rather than left to Core Text to clamp.
        let weightRange: ClosedRange<CGFloat>?

        init(
            family: String,
            regular: String,
            medium: String? = nil,
            variationAxes: Set<Int>?,
            opticalSizeRange: ClosedRange<CGFloat>?,
            weightRange: ClosedRange<CGFloat>? = nil
        ) {
            self.family = family
            self.regular = regular
            self.medium = medium
            self.variationAxes = variationAxes
            self.opticalSizeRange = opticalSizeRange
            self.weightRange = weightRange
        }

        var postScriptName: String { regular }

        func postScriptName(forWeight weight: CGFloat) -> String {
            guard variationAxes == nil, weight >= 450, let medium else { return regular }
            return medium
        }
    }

    static let shared = AteFontRegistry()

    private let faces: [String: Face]

    private init() {
        Self.registerBundledFonts()
        var found: [String: Face] = [:]
        for candidate in Self.candidates {
            guard let font = UIFont(name: candidate.postScriptName, size: 12),
                  font.familyName == candidate.family else { continue }
            found[candidate.key] = candidate.face
        }
        self.faces = found
    }

    func face(for voice: AteVoice, italic: Bool) -> Face? {
        faces[Self.key(voice: voice, italic: italic)] ?? faces[Self.key(voice: voice, italic: false)]
    }

    // MARK: Registration

    /// Registers every `.ttf` in the bundle. Looks in the bundle root and in a `Fonts` subdirectory,
    /// because whether a synchronized Xcode group flattens resources is not something to depend on.
    private static func registerBundledFonts() {
        var urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        urls += Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        guard urls.isEmpty == false else { return }
        CTFontManagerRegisterFontURLs(Array(Set(urls)) as CFArray, .process, true, nil)
    }

    // MARK: The files, as shipped

    private struct Candidate {
        let voice: AteVoice
        let italic: Bool
        let face: Face

        var key: String { AteFontRegistry.key(voice: voice, italic: italic) }
        var postScriptName: String { face.postScriptName }
        var family: String { face.family }
    }

    /// PostScript names and axis ranges read out of the shipped files with fontTools, not guessed
    /// (7 Nov 2026, Eamon's type change). Radio Canada Big's `wght` runs 400–700, Radio Canada's and
    /// Spline Sans Mono's 300–700; none has an optical-size axis. Spectral ships as static cuts, so its
    /// medium is a separate file chosen by weight.
    private static let candidates: [Candidate] = [
        Candidate(voice: .heading, italic: false, face: Face(
            family: "Radio Canada Big",
            regular: "RadioCanadaBig-Regular",
            variationAxes: [AteFontAxis.weight],
            opticalSizeRange: nil,
            weightRange: 400...700
        )),
        Candidate(voice: .display, italic: false, face: Face(
            family: "Radio Canada",
            regular: "RadioCanada-Regular",
            variationAxes: [AteFontAxis.weight],
            opticalSizeRange: nil,
            weightRange: 300...700
        )),
        Candidate(voice: .prose, italic: false, face: Face(
            family: "Spectral", regular: "Spectral-Regular", medium: "Spectral-Medium",
            variationAxes: nil, opticalSizeRange: nil
        )),
        Candidate(voice: .prose, italic: true, face: Face(
            family: "Spectral", regular: "Spectral-Italic", medium: "Spectral-MediumItalic",
            variationAxes: nil, opticalSizeRange: nil
        )),
        Candidate(voice: .mono, italic: false, face: Face(
            family: "Spline Sans Mono",
            regular: "SplineSansMono-Regular",
            variationAxes: [AteFontAxis.weight],
            opticalSizeRange: nil,
            weightRange: 300...700
        )),
        Candidate(voice: .mono, italic: true, face: Face(
            family: "Spline Sans Mono",
            regular: "SplineSansMono-Italic",
            variationAxes: [AteFontAxis.weight],
            opticalSizeRange: nil,
            weightRange: 300...700
        ))
    ]

    static func key(voice: AteVoice, italic: Bool) -> String {
        "\(voice)-\(italic)"
    }
}
