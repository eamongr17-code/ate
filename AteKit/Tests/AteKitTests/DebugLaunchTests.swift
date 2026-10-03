import Foundation
import Testing

@testable import AteKit

/// `-ate-open <route>` and `-ate-fixture <set>`, and the rule that every launch argument is declared
/// in `DebugLaunch.swift` and nowhere else.
@Suite("Debug launch")
struct DebugLaunchTests {

    private static let entry = UUID(uuidString: "A7E00000-0000-4000-8000-000000000142")!

    // MARK: - Routes

    @Test("an entry route is read the way a tapped link is, in either case")
    func entry() {
        #expect(LaunchRoute("entry/a7e00000-0000-4000-8000-000000000142")?.screen == .entry(Self.entry))
        #expect(LaunchRoute("entry/A7E00000-0000-4000-8000-000000000142")?.screen == .entry(Self.entry))
        #expect(LaunchRoute("entry/not-an-id") == nil)
        #expect(LaunchRoute("entry") == nil)
    }

    @Test("pages carry their id; tabs and covers are one word")
    func screens() {
        let id = UUID()
        let raw = id.uuidString.lowercased()
        #expect(LaunchRoute("dish/\(raw)")?.screen == .dish(id))
        #expect(LaunchRoute("place/\(raw)")?.screen == .place(id))
        #expect(LaunchRoute("profile/\(raw)")?.screen == .profile(id))
        #expect(LaunchRoute("summary/\(raw)")?.screen == .summary(id))
        #expect(LaunchRoute("journal")?.screen == .journal)
        #expect(LaunchRoute("saved")?.screen == .saved)
        #expect(LaunchRoute("feed")?.screen == .feed)
        #expect(LaunchRoute("you")?.screen == .you)
        #expect(LaunchRoute("composer")?.screen == .composer)
        #expect(LaunchRoute("suggestions")?.screen == .suggestions)
        #expect(LaunchRoute("welcome")?.screen == .welcome)
        #expect(LaunchRoute("first-run-handle")?.screen == .firstRunHandle)
        #expect(LaunchRoute("kit")?.screen == .kit)
        #expect(LaunchRoute("kit?filter") == nil)
        #expect(LaunchRoute("kit?section=receipt")?.value(.section) == "receipt")
        #expect(LaunchRoute("kit?present=filter")?.value(.present) == "filter")
        #expect(LaunchRoute("kit?present=nope") == nil)
        #expect(LaunchRoute("ratings/4.5")?.screen == .ratings(score: 4.5))
        #expect(LaunchRoute("statement/2026-09")?.screen == .statement(StatementMonth(year: 2026, month: 9)))
        #expect(LaunchRoute("settings")?.screen == .settings(nil))
        #expect(LaunchRoute("settings/appearance")?.screen == .settings(.appearance))
        #expect(LaunchRoute("settings/nope") == nil)
        #expect(LaunchRoute("calendar") == nil)
    }

    @Test("search takes its segment and its words, spaces and all")
    func search() throws {
        #expect(LaunchRoute("search")?.screen == .search(.places))
        let route = try #require(LaunchRoute("search/dishes?q=cacio e pepe&filter"))
        #expect(route.screen == .search(.dishes))
        #expect(route.value(.query) == "cacio e pepe")
        #expect(route.has(.filter))
        #expect(route.has(.filtered) == false)
        #expect(LaunchRoute("search/menus") == nil)
    }

    @Test("a screen's starting state rides on the query")
    func options() throws {
        let sheet = try #require(LaunchRoute("entry/\(Self.entry.uuidString)?sheet=place&add-place"))
        #expect(sheet.value(.sheet) == "place")
        #expect(sheet.has(.addPlace))
        #expect(LaunchRoute("journal?filtered&filter")?.options == [.filtered: "", .filter: ""])
        #expect(LaunchRoute("composer?score")?.has(.score) == true)
        #expect(LaunchRoute("feed?location")?.has(.location) == true)
        #expect(LaunchRoute("search/places?filtered&window=preset")?.value(.window) == "preset")
    }

    @Test("an option a screen does not take, or a value it does not know, refuses the whole route")
    func typos() {
        #expect(LaunchRoute("feed?filtered") == nil)
        #expect(LaunchRoute("composer?sheet=place") == nil)
        #expect(LaunchRoute("journal?flitered") == nil)
        #expect(LaunchRoute("entry/\(Self.entry.uuidString)?sheet=menu") == nil)
        #expect(LaunchRoute("search/places?window=someday") == nil)
    }

    // MARK: - Arguments

    @Test("the last -ate-open wins; fixtures gather from every -ate-fixture, comma-separated")
    func arguments() {
        let arguments = ["app", "-ate-open", "feed", "-ate-fixture", "journal,deep", "-ate-open", "you",
                         "-ate-fixture", "draft"]
        #expect(DebugLaunch.route(in: arguments)?.screen == .you)
        #expect(DebugLaunch.fixtures(in: arguments) == [.journal, .deep, .draft])
        #expect(DebugLaunch.route(in: ["app"]) == nil)
        #expect(DebugLaunch.fixtures(in: ["app", "-ate-fixture"]).isEmpty)
    }

    // MARK: - One file

    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func swiftFiles(in folder: String) -> [URL] {
        let root = repo.appending(path: folder)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        return files.filter { $0.pathExtension == "swift" && $0.path.contains("/.build/") == false }
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    @Test("every argument a UI test passes is declared, every route it opens reads, every fixture exists")
    func uiTestsSpeakDebugLaunch() throws {
        let tests = Self.swiftFiles(in: "AteUITests")
        try #require(tests.isEmpty == false, "the UI tests are beside the package")
        for file in tests {
            let text = try String(contentsOf: file, encoding: .utf8)
            let name = file.lastPathComponent
            for token in Self.matches(#""(-ate-[a-z0-9-]+)""#, in: text).map({ $0[1] }) {
                #expect(DebugLaunch.declared.contains(token), "\(name): \(token) is not in DebugLaunch")
            }
            for raw in Self.matches(#""-ate-open",\s*"([^"\\]+)""#, in: text).map({ $0[1] }) {
                #expect(LaunchRoute(raw) != nil, "\(name): -ate-open \(raw) is not a route")
            }
            for raw in Self.matches(#""-ate-fixture",\s*"([^"\\]+)""#, in: text).map({ $0[1] }) {
                for set in raw.split(separator: ",") {
                    #expect(DebugLaunch.Fixture(rawValue: String(set)) != nil, "\(name): no fixture \(set)")
                }
            }
        }
    }

    @Test("no -ate- string outside DebugLaunch.swift, in the app or in AteKit")
    func oneFile() throws {
        let sources = Self.swiftFiles(in: "App") + Self.swiftFiles(in: "AteKit/Sources")
        try #require(sources.isEmpty == false)
        for file in sources where file.lastPathComponent != "DebugLaunch.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let strings = Self.matches(#""[^"\n]*-ate-[a-z][^"\n]*""#, in: text)
            #expect(strings.isEmpty, "\(file.lastPathComponent): \(strings.map { $0[0] })")
        }
    }
}
