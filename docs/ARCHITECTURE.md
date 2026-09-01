# Ate — architecture decisions (ratified 2026-08-31)

Every foundational decision, its rationale, and what was rejected. Changing a row here is a
strategy-significant call (flag to the CEO digest). Don't relitigate silently.

| Layer | Decision | Rationale / rejected |
|---|---|---|
| Language | Swift 6, strict concurrency from day one | Retrofitting Sendable is misery; starting strict is ~free. *Rejected: Swift 5 mode "for now".* |
| UI | SwiftUI, 100% | The point of the reboot. UIKit only if a control forces it. *Rejected: hybrid shells.* |
| Min iOS | **26** | Native Liquid Glass, current SwiftUI, zero availability checks. Launch market is on current iPhones. *Rejected: iOS 18 + conditional glass — the dual-rendering trap that burned the legacy build.* |
| Architecture | Vanilla MVVM on `@Observable`; features as folders; protocol seams for services | Solo-scale app; testability via extracted pure logic, not framework ceremony. *Rejected: TCA, VIPER, DI containers.* |
| Modularity | App target + ONE local package `AteKit` (models, API clients, pure logic + tests) | Keeps logic UI-free and fast to test; module graphs are a scale tool we don't need. *Rejected: per-feature packages, Tuist/XcodeGen.* |
| Backend | Existing Supabase project via `supabase-swift`; schema/RLS/edge fns carried over intact | Reviewed as the legacy build's best asset. *Rejected: Firebase, custom API.* |
| Server state | Thin per-domain API clients + `@Observable` stores; **every list query paginated; UUID keys everywhere** | The legacy client's sins (name keys, whole-table bootstrap) die here. *Rejected: offline-first local mirror (V1 doesn't need it).* |
| Design tokens | One `App/Theme/Theme.swift` (semantic colors, type ramp, spacing); Apple components everywhere else | The brand-coating seam. Replaces the entire legacy token pipeline. *Rejected: any generated-token machinery, Figma parity.* |
| Testing | Swift Testing on AteKit; ONE XCUITest smoke flow; contract tests decoding real staging rows in CI | Mirrors what paid rent (334 unit tests) and drops what didn't (48 one-off UI captures). *Rejected: snapshot suites, broad UI automation.* |
| Observability | Sentry (crashes) + TelemetryDeck (events), wired before any feature; funnel: `log_started → restaurant_picked → dish_picked → rated → posted → receipt_shared` | Legacy shipped 78 OTAs blind. *Rejected: Firebase Analytics, "later".* |
| CI | GitHub Actions for everything: PRs (lint/build/test/contract, <10 min) and Beta archive → TestFlight internal on every merge to main, signed by `xcodebuild -allowProvisioningUpdates` with an App Store Connect API key (cloud signing; no certs in secrets) | Signing is still Apple's problem, but one CI system beats two. *Rejected: fastlane + match; Xcode Cloud (a second pipeline with its own config surface for one step).* |
| Environments | Local Supabase CLI stack · staging project (Debug builds, all tests, synthetic data) · prod (Release + CI migrations only) | Ends QA-pollutes-prod structurally. Secrets via gitignored xcconfig + CI secrets; nothing in git. |
| Release | Merge → internal TestFlight automatically; tag → external/App Store, **Eamon-approved only** | The pipeline is the ship gate; CI green is the only sign-off. |

## Repository shape
```
App/            Xcode project — Features/ (Feed, Log, DishDetail, Diary, Search), Theme/, Resources/
AteKit/         local Swift package: models, API clients, pure logic + tests
supabase/       migrations + edge functions (full history imported from legacy)
docs/           PRODUCT.md · ARCHITECTURE.md · backend/ (data model + contract)
.claude/agents/ the org (see AGENTS.md)
```

## Standing rules
- Binary artifacts never enter git (legacy lesson: 96 MB of committed QA screenshots).
- Docs budget is fixed (see AGENTS.md); narrative lives in PRs.
- Port solved logic from the legacy repo with its tests; never rewrite proven behaviour from scratch.
- PostgREST upsert targets need TOTAL unique constraints (the 0014/0016 outage); `dishes_identity_uq`
  is partial by design → dish creation stays select-then-insert.

Full foundations doc: https://claude.ai/code/artifact/d4a8e23f-e2c1-4b9b-8a6d-7340e2ed7bf7
