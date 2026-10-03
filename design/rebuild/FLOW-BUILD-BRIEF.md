# Phase 3 — building the five flows (shared brief)

Eamon approved the kit and the V2 shell on his phone (build 85, 3 Oct 2026). Each flow is now assembled
**from the kit only**, inside the V2 shell, wired to the existing AteKit stores and services.

## Read first
`design/rebuild/README.md` · `pattern-contract.html` (binding) · `HISTORY-AUDIT.md` (earlier rulings and
the build behaviours the mockups do not draw; your flow's line is your checklist) · your flow's mockup ·
`KIT-BRIEF.md` and `App/DesignSystem/Kit/` (open `KitGalleryScreen` to see every component) ·
`SKELETON-BRIEF.md` and `App/V2/Shell/`.

The old screen for your flow (`App/<Flow>/`) is the record of behaviour: states, edge cases, analytics
events, store calls. **Port its logic; do not port its look.** `docs/DESIGN.md` and `design/v1` lose
to the contract and the history audit.

## Rules
- **Compose from the kit.** No colour, font, radius, shadow or spacing literal in `App/V2/` (lint enforces). If the kit lacks something, add a NEW file under `App/DesignSystem/Kit/` and list it in the PR; never edit an existing kit file. Where your mockup and the kit disagree on how an element looks, the kit wins.
- **Stay in your folders** (table below). Never edit `App/V2/Shell/`, another flow's folder, the old app (`App/<old flows>/`, `App/Root/`), `supabase/`, or `design/`.
- **Seams are already cut.** Each tab root, each pushed page and the composer sheet is a stub file in its flow folder; replace the stub's body, keep its type name and initialiser. Tab stores live in your `<Flow>Stores` type.
- Logic belongs in AteKit as plain testable types with Swift Testing tests. Reuse the existing stores (`JournalStore`, `EntryListStore`, `FeedEditionStore`, `SearchStore`, `YouStore`, `SavedDishesStore`, `SaveAction`, page stores) and the existing analytics events; do not rename events.
- Every state: loading (kit skeleton), empty (kit empty state), failed (the build's retry behaviour), signed out, offline entry. Light and dark. Reduce Motion.
- No `#if DEBUG` in a V2 screen; launch arguments live in `DebugLaunch`.
- Native iOS 26 chrome only. Location is asked only on Near me and in the place picker.

## Folders
| Flow | Owns | Stubs to fill |
|---|---|---|
| Journal | `App/V2/Journal/` | `JournalRoot`, Saved, filter sheet, calendar zoom (month, year), `V2SuggestionsPage` |
| Compose and Entry | `App/V2/Compose/`, `App/V2/Entry/` | `ComposerSheet` (write, score slide, diet unfold, place sheet, posting), printed summary and share, `V2EntryPage` (own and others'), fix-a-dish sheet |
| Feed | `App/V2/Feed/` | `FeedRoot` (Top Ate hero and rows, Because you loved, New to the record, shelves, latest receipts, the end), area Menu, cravings sheet, actions sheet use |
| Browse | `App/V2/Search/`, `App/V2/Place/`, `App/V2/Dish/` | `SearchRoot`, filter sheet, `V2PlacePage`, `V2DishPage`, `V2TagPage` |
| You and first run | `App/V2/You/`, `App/V2/Profile/`, `App/V2/Settings/`, `App/V2/FirstRun/` | `YouRoot`, `V2RatingsPage`, `V2ProfilePage`, `V2SettingsPage` (+ pages), Welcome, Handle |

## The seams (commit 66f0e73)
- Roots: `init(router: TabRouter<JournalStores | V2FeedStores | SearchStores | YouStores>, app: AppModel)`. The Feed's stores type is `V2FeedStores` (the old app owns the name `FeedStores`).
- Stores: `@MainActor struct … { init(services: AteServices) }`, built by the router on first show.
- Pages: `V2EntryPage(_ entry: EntryRoute, context:)`, `V2SuggestionsPage(context:)`, `V2ProfilePage(userID:context:)`, `V2PlacePage(placeID:context:)`, `V2DishPage(dishID:context:)`, `V2TagPage(tag:context:)`, `V2RatingsPage(score:context:)`, `V2SettingsPage(page:context:)`.
- `ComposerSheet(app: AppModel)`; `app.isComposing = false` closes it. Open the composer from anywhere with `app.compose(ComposerPresentation(origin: …, assetIdentifiers: …, editing: …))` (ask the gate first); `ComposerSheet` reads `app.composing` for the origin, the photos it opens holding and the entry being edited.
- `V2PageContext`: `app`, `tab`, `source`, `services`, `gate`, `saves`, `open(_:from:)`. `AppModel` owns the one `saves` (SaveAction) and `savedDishes`.
- Sheets: use `AteSheetScaffold` (fitted detent, one header). Selectable diet codes are `AteDietPill`.

## Working from a cloud thread (no Xcode there)
- Branch from `claude/project-thread-2f9ty8`; open a **draft PR back to that branch** (not main). The PR triggers CI on a Mac runner: SwiftLint strict, the app build, AteKit tests. That is your compiler; push small commits and read the CI log.
- You cannot run the simulator. Say so in the PR. The lead runs each PR on the simulator on Eamon's Mac, screenshots every screen in light and dark, and compares it with the mockup before merging.
- PR body: the screens built, each state covered, any new kit file, every place the contract or mockup could not be followed and why, and what you could not verify without a simulator.

## Done
CI green · every screen and state of the mockup and of your HISTORY-AUDIT line built · analytics events preserved · tests for any logic moved into AteKit · the flow's old screens untouched.
