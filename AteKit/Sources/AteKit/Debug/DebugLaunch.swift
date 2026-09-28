import Foundation

/// **Every launch argument the app reads — here, and nowhere else.** SwiftLint's
/// `launch_arguments_in_one_place` fails a `-ate-` string in any other file, and `DebugLaunchTests`
/// fails a UI test that passes an argument this file does not declare.
///
/// A simulator cannot be tapped from a shell and a UI test wants a state without a walk to it, so a
/// Debug build reads three kinds of argument:
///
/// - `-ate-open <route>` — a screen, read as the link `ate://<route>` (``LaunchRoute``):
///   `entry/<id>`, `dish/<id>`, `composer?score`, `search/dishes?q=ra`, `settings/appearance`.
/// - `-ate-fixture <set>` — a preview data set on top of `-ate-preview-data` (``Fixture``). Repeat
///   it, or comma-separate: `-ate-fixture journal,deep`.
/// - a ``Flag`` — a switch that changes how the app behaves rather than where it opens.
///
/// An installed app has no way to set an argument. Everything but the first three switches is
/// compiled into Debug only.
public enum DebugLaunch {
    /// The switches.
    public enum Flag: String, CaseIterable, Sendable {
        /// Signs in as the seeded staging account without a tap (Debug and Beta).
        case debugSignIn = "-ate-debug-signin"
        /// Hides `Welcome`'s staging door, so a parity still is exactly what Release draws (Debug and
        /// Beta).
        case hideDebugDoor = "-ate-hide-debug-door"
        /// A UI-test run starts from nothing: no draft, no dismissed suggestions, no launch moment —
        /// one test's leftovers are never the next test's opening screen. (The launch moment reads
        /// it in every build.)
        case uiTesting = "-ate-ui-testing"
        #if DEBUG
        /// The whole app on in-memory services: the artboards' own entries, no backend.
        case previewData = "-ate-preview-data"
        /// The sort held back 6s after Post, so the slow case can be driven on a sorter that answers
        /// fast.
        case slowSort = "-ate-slow-sort"
        /// "Posting…" held up to 8s rather than 3.5, so a drive's taps all land inside the hold.
        case longHold = "-ate-long-hold"
        /// The dish and place pages' reads held back 2s, to see what a page draws before they answer.
        case slowDetail = "-ate-slow-detail"
        /// How long a dish or place page takes to settle, appended to `Documents/detail-timings.txt`.
        case profileDetail = "-ate-profile-detail"
        /// Undo and Redo buttons in the composer's header — XCUITest can neither shake nor
        /// three-finger swipe.
        case undoDrive = "-ate-undo-drive"
        /// The share card's rendered PNG, written to `Documents` for a drive to collect.
        case dumpShare = "-ate-dump-share"
        /// The share card's render fails, for its error state.
        case failShareRender = "-ate-fail-share-render"
        #endif
    }

    public static func isOn(_ flag: Flag) -> Bool {
        ProcessInfo.processInfo.arguments.contains(flag.rawValue)
    }

    #if DEBUG
    /// The preview data sets. Each is in-memory only; none ever reaches a server.
    public enum Fixture: String, CaseIterable, Sendable {
        /// The first-day journal: signed in, nothing written.
        case empty
        /// A longer journal — a dozen visits over four months and two years — for filters and sorts.
        case journal
        /// The design's visit carrying its dietary tags (`DietTagsB`).
        case tags
        /// A long-handle, photo-less, three-dish visit at the top of the feed.
        case long
        /// Long profile, place and dish lists, to scroll to mid-list. UI-test runs only.
        case deep
        /// Every list read fails.
        case offline
        /// Saved dishes without their cover photos.
        case noCovers = "no-covers"
        /// The entry page's read fails: offline, or the entry is gone.
        case entryOffline = "entry-offline"
        case entryGone = "entry-gone"
        /// The photo library: refused, empty in the window, or never asked yet.
        case photosDenied = "photos-denied"
        case noPhotos = "no-photos"
        case photosUndetermined = "photos-undetermined"
        /// The composer's draft seeded with the design's own sentence, tokens and three photos.
        case draft
    }

    static let openArgument = "-ate-open"
    static let fixtureArgument = "-ate-fixture"

    /// User defaults set from the command line (`-ate-seed-place "<name>"`): the seeded draft's place
    /// name, for the long-name truncation.
    public static let seedPlaceKey = "ate-seed-place"
    /// …and `-ate-handle-text <text>`: typed into the handle field, for its checking, taken and
    /// malformed marks.
    public static let handleTextKey = "ate-handle-text"

    /// Where this launch opens, if it asked. Read once. A route that does not read is a typo in a
    /// drive, and stops the launch rather than opening somewhere else.
    public static let route: LaunchRoute? = route(in: ProcessInfo.processInfo.arguments)

    /// The fixtures this launch asked for.
    public static let fixtures: Set<Fixture> = fixtures(in: ProcessInfo.processInfo.arguments)

    public static func has(_ fixture: Fixture) -> Bool { fixtures.contains(fixture) }

    /// Whether the route this launch opens carries an option — only ever true on its own screen.
    public static func has(_ option: LaunchRoute.Option) -> Bool { route?.has(option) == true }

    static func route(in arguments: [String]) -> LaunchRoute? {
        guard let raw = values(after: openArgument, in: arguments).last else { return nil }
        guard let route = LaunchRoute(raw) else {
            preconditionFailure("\(openArgument) \(raw): not a route (see LaunchRoute)")
        }
        return route
    }

    static func fixtures(in arguments: [String]) -> Set<Fixture> {
        let names = values(after: fixtureArgument, in: arguments)
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return Set(names.map { name in
            guard let fixture = Fixture(rawValue: name) else {
                preconditionFailure("\(fixtureArgument) \(name): not a fixture (see DebugLaunch.Fixture)")
            }
            return fixture
        })
    }

    /// Every argument declared here — what a UI test may pass.
    static var declared: Set<String> {
        Set(Flag.allCases.map(\.rawValue)).union([
            openArgument, fixtureArgument, "-" + seedPlaceKey, "-" + handleTextKey
        ])
    }

    private static func values(after flag: String, in arguments: [String]) -> [String] {
        arguments.indices.compactMap { index in
            guard arguments[index] == flag, arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
    }
    #endif
}
