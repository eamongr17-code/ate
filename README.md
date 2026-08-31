# Ate

**What should I order here?** Dish reviews, native iOS. Log the dishes you eat, see what everyone's
eating, share what's great.

- `docs/PRODUCT.md` — the strategy (the dish is the atom; V1 = global feed + log + share).
- `docs/ARCHITECTURE.md` — every stack decision, with rejected alternatives.
- `AGENTS.md` — how the org that builds this operates.

## Stack
Swift 6 · SwiftUI · min iOS 26 · `AteKit` local package · Supabase (`supabase-swift`) ·
Sentry + TelemetryDeck · GitHub Actions + Xcode Cloud → TestFlight.

## Running it
```
git clone <repo> && cd ate
supabase start                      # local backend (Docker)
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # fill from 1Password/staging
open Ate.xcodeproj                  # build the Ate scheme — Debug points at staging
swift test --package-path AteKit    # unit tests
```

Debug builds talk to **staging**; only Release talks to prod. Migrations apply via CI, never by hand.

*Predecessor: the Expo build lives at `eamongr17-code/ate-legacy` (archived).*
