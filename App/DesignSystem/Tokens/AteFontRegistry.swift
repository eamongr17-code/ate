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
        /// DM Mono is not variable: its medium is a separate file, chosen by weight.
        private let medium: String?
        let variationAxes: Set<Int>?
        let opticalSizeRange: ClosedRange<CGFloat>?

        init(
            family: String,
            regular: String,
            medium: String? = nil,
            variationAxes: Set<Int>?,
            opticalSizeRange: ClosedRange<CGFloat>?
        ) {
            self.family = family
            self.regular = regular
            self.medium = medium
            self.variationAxes = variationAxes
            self.opticalSizeRange = opticalSizeRange
        }

        var postScriptName: String { regular }

        func postScriptName(forWeight weight: CGFloat) -> String {
            guard variationAxes == nil, weight >= 450, let medium else { return regular }
            return medium
        }
    }

    static let shared = AteFontRegistry()

    private let faces: [String: Face]
    let faceNames: [String]

    var isAvailable: Bool { faces.isEmpty == false }

    private init() {
        Self.registerBundledFonts()
        var found: [String: Face] = [:]
        var names: [String] = []
        for candidate in Self.candidates {
            guard let font = UIFont(name: candidate.postScriptName, size: 12),
                  font.familyName == candidate.family else { continue }
            found[candidate.key] = candidate.face
            names.append(contentsOf: UIFont.fontNames(forFamilyName: candidate.family))
        }
        self.faces = found
        self.faceNames = Array(Set(names)).sorted()
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

    /// PostScript names and axis ranges read out of the shipped files with a Core Text dump, not
    /// guessed: Bricolage's default instance is its 96pt ExtraBold, and Newsreader's is 16pt Regular.
    private static let candidates: [Candidate] = [
        Candidate(voice: .display, italic: false, face: Face(
            family: "Bricolage Grotesque",
            regular: "BricolageGrotesque-96ptExtraBold",
            variationAxes: [AteFontAxis.weight, AteFontAxis.opticalSize],
            opticalSizeRange: 12...96
        )),
        Candidate(voice: .prose, italic: false, face: Face(
            family: "Newsreader",
            regular: "Newsreader16pt-Regular",
            variationAxes: [AteFontAxis.weight, AteFontAxis.opticalSize],
            opticalSizeRange: 6...72
        )),
        Candidate(voice: .prose, italic: true, face: Face(
            family: "Newsreader",
            regular: "Newsreader16pt-Italic",
            variationAxes: [AteFontAxis.weight, AteFontAxis.opticalSize],
            opticalSizeRange: 6...72
        )),
        Candidate(voice: .mono, italic: false, face: Face(
            family: "DM Mono", regular: "DMMono-Regular", medium: "DMMono-Medium",
            variationAxes: nil, opticalSizeRange: nil
        )),
        Candidate(voice: .mono, italic: true, face: Face(
            family: "DM Mono", regular: "DMMono-Italic",
            variationAxes: nil, opticalSizeRange: nil
        ))
    ]

    static func key(voice: AteVoice, italic: Bool) -> String {
        "\(voice)-\(italic)"
    }
}
