# Phase 2b — the new app shell (V2), side by side

Eamon approved the kit gallery on 3 Oct 2026 ("no notes"). This task builds the shell every rebuilt
flow will live in. It ships **beside** the current app, not under it.

## Decision (lead, supersedes skeleton-spec section 6 step 2)
The old screens were built for the custom chrome. Swapping native chrome under them would put a
half-migrated app in front of Eamon. So V2 is a second root, reached by a switch, and the old app is
untouched until cutover:
- `App/V2/` holds the new shell and, later, each flow (`App/V2/Journal/`, `App/V2/Feed/` …).
- Entry: launch flag `-ate-v2` (declare in `DebugLaunch`) and, in Debug and Beta builds, a "New app" row at the foot of Settings beside the Component kit row. The choice persists (`AtePreferences`) so a TestFlight user stays in V2 until they switch back from V2's own Settings stub.
- Cutover later = make V2 the root and delete `App/<old flow>/`, the Legacy* components and the custom chrome. Not in this task.

## Read first
`design/rebuild/README.md`, `pattern-contract.html` (binding), `skeleton-spec.html` (sections 0–2 and 4),
`HISTORY-AUDIT.md`, and the five mockups for what each tab root shows.

## Build
1. **`AppModel`** (`@Observable`): session state, the sign-in gate, the owed handle, outbox drain on foreground, incoming entry links. Reuse `AteServices`, `SessionGate`, the outbox and link inbox as they are; no AteKit behaviour changes.
2. **`TabShell`**: native `TabView`, four tabs (Journal, Feed, Search, You) with Lucide icons, `tabBarMinimizeBehavior(.onScrollDown)`, the selected tab in the system's quiet state (no tint colour). **+ is a tab** in the bar's detached trailing slot (the search-role slot): plain glass, ink plus; selecting it presents the composer sheet and restores the previous selection, so the selected tab never changes. The tab bar stays on every pushed page.
3. **Four `TabRouter`s**: each owns its `[Route]` path, its stores (created on first show), and scroll-to-top on re-tap. One `navigationDestination(for: Route.self)` in the shell. Reuse the existing `Route` enum.
4. **Root header**: the kit's `AteRootHeader`, title and glass group on one row, and now the scroll behaviour the kit left out: the title collapses to a centred inline title under the system scroll-edge effect (Journal's inline title is the month; Feed's carries the city). No custom frost. Verify on the simulator that the fade is soft and even with no band.
5. **Pushed pages**: native inline bar, native back, trailing controls as glass toolbar items, `•••` as a `Menu`. System swipe-back.
6. **Sheets**: `AteSheetScaffold`. The composer is presented as a sheet by the shell.
7. **Tab roots in this task are placeholders built only from the kit**: each shows its real `AteRootHeader` and a kit `AteSkeleton` list, so chrome, scrolling, minimise and collapse can be judged. Pushed-page placeholder: one kit screen reachable from each root. The composer sheet placeholder: the scaffold with close and the muted tick. No flow logic yet.
8. **Debug launch**: every V2 launch argument lives in `DebugLaunch`; no `#if DEBUG` inside a V2 screen.
9. **Lint**: extend the kit literal rules to `App/V2/`.
10. **UI tests**: add `V2ShellUITests` (tabs switch, + opens the sheet and leaves the tab, push keeps the tab bar, re-tap scrolls to top). Leave the old UI tests alone until cutover.

## Verify and report
- `swift test --package-path AteKit` green; `xcodebuild -scheme Ate build` clean (own `-derivedDataPath`); SwiftLint strict clean; the new UI test passes on the iPhone 17 Pro simulator.
- Screenshots, light and dark, to the scratchpad path the dispatch names: each tab root at rest and scrolled (title collapsed, bar minimised), a pushed page, the composer sheet, and the + tab mid-tap if capturable.
- Commit in small steps to `claude/project-thread-2f9ty8`, push. No PR, never main, nothing under `supabase/`.
- Report: files, what was reused, every place native iOS 26 could not do what the contract says and what you did instead, anything ambiguous.
