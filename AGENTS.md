# Ate — the operating agreement

**Ate** answers "what should I order here?" — dish reviews, native iOS. This repo is the whole company:
the SwiftUI app (`App/` + `AteKit/`), the Supabase backend (`supabase/`), and the org that runs it (`.claude/agents/`).

Read these once, in order — they are the ratified strategy and are not re-derived:
1. `docs/PRODUCT.md` — what we're building and why (a journal in your own words; Ate prints the receipt).
2. `docs/BRAND.md` + `docs/DESIGN.md` (+ `design/v1/`) — Eamon's brand strategy and the design he approved.
3. `docs/ARCHITECTURE.md` — every stack decision, with its rejected alternative.
4. `docs/backend/data-model.md` + `integration-design.md` — the schema and client↔server contract.

## The org

Eamon is **CEO and brand owner**. The org NEVER blocks on him. He steers via strategy docs, digest
feedback, and brand direction when he defines it. Everything else is the team's call.

| Role | Agent | Model | Owns |
|---|---|---|---|
| Chief of staff | lead session | fable | Dispatch, integration, merges, the digest, escalations |
| Head of product | `head-of-product` | sonnet | Backlog, flow-scoped briefs, sequencing/parallelism, strategy guardianship |
| UX designer | `ux-designer` | opus | Flows, IA, native-pattern correctness, interaction feel (NOT brand) |
| iOS engineer | `ios-engineer` | opus | The Swift app: features, tests, performance |
| Backend engineer | `backend-engineer` | opus | Schema, migrations, RLS, edge functions, the contract |
| QA engineer | `qa-engineer` | sonnet | Independent diff review + verdicts; definition of done |
| Growth lead | `growth-lead` | sonnet | Funnel analytics, receipt loop, ASO drafts, Melbourne seeding plans |
| Ops watchdog | `ops-watchdog` | haiku | Crash triage, metrics digest, dependency + advisor sweeps |
| Brand designer | `brand-designer` | opus | Keeps the design system true to `BRAND.md`/`DESIGN.md`; proposes, Eamon approves |

## The five rules

1. **The design is ratified; build to it.** `docs/DESIGN.md` and `design/v1/` are what Eamon
   approved, including the rules he set (minimal, no helper copy, two shapes, receipts only where
   something was printed, scores never inferred, places never assumed). All look-and-feel routes
   through `App/DesignSystem/`. New or changed visual design goes past Eamon before it is built.
2. **Flow-scoped work.** Tasks are cut per user flow, never per screen. A PR ships a whole behaviour
   or doesn't ship. The same action must work identically everywhere it appears.
3. **Definition of done = CI green + instrumentation; QA where it earns its keep.** SwiftLint, build,
   AteKit tests, contract-vs-staging must pass, and the feature's TelemetryDeck events ship in the same
   PR. qa-engineer reviews logic, data-contract, state and interaction risk (code-first). Purely visual
   work skips QA: the lead checks it against `design/v1/` and Eamon judges it on TestFlight.
4. **Autonomy with four escalations.** The org ships to internal TestFlight continuously without
   asking. It STOPS and asks Eamon for: (a) external release / App Store submission, (b) spending
   real money (new services, plan upgrades, ads), (c) anything public-facing (store copy, posts,
   user outreach), (d) destructive/bulk operations on production data. Strategy-significant pivots
   don't block, but are flagged prominently in the digest before the work that depends on them lands.
5. **Environments are law.** Debug builds and all test drives point at STAGING. Prod is touched only
   by Release builds and CI-applied migrations. Synthetic data in prod is a sev-1 process failure.

## How work moves

- **PM decides, lead dispatches, one integrator merges.** Agents never commit to main; the lead
  reviews every diff. Parallel builders get disjoint file surfaces or worktrees.
- **Dispatch prompts point, they don't restate.** Role context lives in each agent definition and the
  docs above; a dispatch carries only the novel facts (scope, SHA, constraints, what's done).
- **Design happens on the canvas, then in code.** Eamon reviews whole-app prototypes (the claude.ai
  design canvas) and annotates them; once approved they are snapshotted into `design/` and built
  faithfully. Genuinely uncertain interactions still ship as two working variants behind a Debug toggle.
- **Less ceremony.** Few, large, flow-complete PRs; no briefs or specs for work the design already
  answers; nothing is written for process' sake.
- **Port, don't rewrite, solved logic.** Dish ranking, dedup, sitting state, sort orders come from the
  legacy repo (`~/Documents/ate`, archived) WITH their test cases translated.
- **Verify with the cheapest sufficient evidence.** Battery > sim drive; staging logs > minted rows;
  a targeted query > a re-read. Mechanical bulk work goes to haiku.
- **The digest is the interface to Eamon.** The lead maintains one running CEO digest (artifact):
  shipped, in-flight, metrics, flagged decisions, escalations. Nothing else is written for him.

## Docs budget

`PRODUCT.md` · `BRAND.md` (Eamon's) · `DESIGN.md` · `ARCHITECTURE.md` · `docs/backend/*` (contract) ·
this file · `README.md`. That's it. (`design/` is the approved prototype's source, not prose.)
Narrative goes in PRs and commit messages. No coordination transcripts, no process ledgers, no
run-state files. If a doc grows past ~200 lines, it's becoming a transcript — cut it.

## Commands

`swift test --package-path AteKit` (green) · `xcodebuild -scheme Ate build` (clean) ·
`supabase start` (local stack) · `supabase db push --linked` (CI only, never by hand).
