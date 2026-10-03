# Phase 2a — the component kit and its gallery

Eamon approved the five flow designs on 3 Oct 2026 and set the build rule: **atomic, components first**.
This brief is the first build task. It ships no screen changes.

## Read first
1. `design/rebuild/README.md` — decisions and the build rule.
2. `design/rebuild/pattern-contract.html` — binding. Where a mockup disagrees with it, the mockup is wrong.
3. `design/rebuild/skeleton-spec.html` — section 0 (components first) and section 3 (48 → 17).
4. `design/rebuild/HISTORY-AUDIT.md` — earlier rulings and build behaviours the mockups do not draw.
5. The five mockups in `design/rebuild/*.html` for how each component looks in context.

`docs/DESIGN.md` and `design/v1/` are stale where they disagree with the above or with the current
build (paper is flat, no barcode, Edge B is the fitted wave, native chrome). The contract, the
history and the build win.

## Build
A kit under `App/DesignSystem/Kit/`. Reuse the existing implementations (move or wrap; do not rewrite
solved code such as the inline token editor, the star slider, the image pipeline, the wave edge).
Existing screens keep compiling and are not restyled in this task; the old chrome components stay
until the skeleton task removes them.

**Atoms**
- `AteScoreToken` — filled star + one decimal, butter pill, DM Mono; brick for a 6; an unrated dish renders nothing (empty slot). Sizes: inline, row, hero.
- `AteDietChip` — GF DF V VG NF.
- `AteThumb` — ONE component for a dish thumbnail: photo or letter tile, same size and radius in a list, never a ring. Sizes from a small enum (row 56/r16, menu 48/r14, shelf card, hero).
- `AtePhotoCluster` — the tilted, overlapping cluster; the only place the 3pt surface ring appears.
- `AteAvatar`, `AteSaveButton` (the one bookmark; on-image glass variant and plain row variant).
- `AteGlassDisc` — 44pt icon button on native `.glassEffect`; `AteGlassGroup` for a root's ≤3 controls.
- `AteInkPill` — the one commit button (52 high in sheets, 44 in empty states).
- `AteKey` — composer toolbar key (labelled Score/Place, icon-only Diet).

**Composites**
- `AteDishRow`, `AteEntrySlip` (one anatomy: Journal, Feed, Profile, place visits; Feed hides words past two dishes), `AteTornEdge` (Edge B: `P = W / round(W/12)`, `y = 2.1 − 1.5·cos(2πx/P)`; flat paper).
- `AteShelfCard` (16pt radius, token top-left and glass bookmark top-right equally inset, name then place beneath, flush left), `AteHeroCard` (no rank numeral), `AteRankedRow`.
- `AteReceipt` — dishes lead; dashed rule; place and address as mono fine print; order number, date, count, average; handle and wordmark. Straight. No barcode. Scores only.
- `AteEmptyState` — one 40pt Bricolage 800 line, centred between header and tab bar, at most one ink pill 22pt below.
- `AteSkeleton`, `AteFilterChipRow`, `AteRootHeader` (title or wordmark leading and the glass group trailing on ONE row; city as subtitle), `AteSheetScaffold` (native sheet; close glass disc top-left, primary glass disc top-right, title 30, optional ink pill with live count), `AteActionsSheet` (Save, Share, Report, Block — the same everywhere).

**Gallery** — `KitGalleryScreen`, in Debug and Beta builds only: every atom and composite in every
state (rated/unrated, photo/letter tile, 5.0 and 6, saved/unsaved, loading, empty, long names), light
and dark. Reachable with `-ate-open kit` (declare it in `DebugLaunch`) and from a row at the foot of
Settings in Debug and Beta. This is where Eamon judges the kit on his phone.

**Lint** — a SwiftLint custom rule: no colour, font, radius or shadow literal in `App/` outside
`App/DesignSystem/`. If existing screens trip it, scope the rule to `App/DesignSystem/Kit/` plus new
flow folders for now and say so; do not restyle old screens to satisfy it.

## Verify and report
- `swift test --package-path AteKit` green; `xcodebuild -scheme Ate build` clean with your own `-derivedDataPath`; SwiftLint strict clean.
- Simulator screenshots of the gallery, light and dark, saved under the scratchpad path the dispatch names.
- Commit in small steps to `claude/project-thread-2f9ty8` and push. Never commit to main, open no PR, touch nothing under `supabase/`.
- Report: each component with its file, what was reused vs new, every place you could not follow the contract exactly and why, and anything in the contract that is ambiguous for a builder.
