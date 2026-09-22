# Ate

**What should I order here?** Dish reviews, native iOS. Log the dishes you eat, see what everyone's
eating, share what's great.

- `docs/PRODUCT.md` — the strategy (a journal in your own words; Ate prints the receipt).
- `docs/DESIGN.md` + `design/v1/` — the approved design, and the rules that go with it.
- `docs/ARCHITECTURE.md` — every stack decision, with rejected alternatives.
- `AGENTS.md` — how the org that builds this operates.

## Stack
Swift 6 · SwiftUI · min iOS 26 · `AteKit` local package · Supabase (`supabase-swift`) ·
Sentry + TelemetryDeck · GitHub Actions + Xcode Cloud → TestFlight.

## Running it
```
git clone <repo> && cd ate
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # REQUIRED — see below
supabase start                      # local backend (Docker)
open Ate.xcodeproj                  # build the Ate scheme — Debug points at staging
swift test --package-path AteKit    # unit tests
```

**`Config/Secrets.xcconfig` is required to build at all**, including for the UI tests: it is
gitignored, and without it the app resolves no environment and shows the configuration-error screen.
The example file is filled in — the Supabase keys in it are publishable, and RLS is the security
boundary — so copying it is enough; nothing has to be looked up.

Debug builds talk to **staging**; only Release talks to prod. Migrations apply via CI, never by hand.

## Driving it

```
xcodebuild test -scheme Ate -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:AteUITests -resultBundlePath run.xcresult
xcrun xcresulttool export attachments --path run.xcresult --output-path shots
```

`AteUITests` drives the core loop against an in-memory service (`-ate-preview-data`), so it needs no
backend, no session and no network, and attaches a screenshot at every step. The Debug-only launch
arguments that put a single screen into a state — `-ate-preview-empty`, `-ate-open-composer`,
`-ate-seed-draft`, `-ate-open-scoring`, `-ate-open-entry`, `-ate-open-place-sheet`,
`-ate-open-dish-sheet`, `-ate-design-gallery` — are listed in `App/Compose/ComposerDebugLaunch.swift`.

*Predecessor: the Expo build lives at `eamongr17-code/ate-legacy` (archived).*
