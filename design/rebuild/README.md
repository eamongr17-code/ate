# Ate rebuild — the working set (3 Oct 2026)

Eamon paused round-based work and chose to rebuild the app layer in place. This folder is what every
rebuild thread reads. Decisions here are settled; do not re-ask them.

| File | What it is |
|---|---|
| `pattern-contract.html` | The cross-cutting UI rules every flow follows. Binding. |
| `skeleton-spec.html` | Phase 2 brief: composition root, native navigation and chrome, 48 → 17 components. |
| `compose-entry.html` | The approved Compose and Entry mockup. Also the visual kit every other mockup copies. |
| `first-run.html` | Onboarding (6 Oct, approved, PR #117): the photo ask, first entry from your photos, TipKit tips. Superseded after Handle by `onboarding-v2.html`. |
| `onboarding-v2.html` | Onboarding v2 (10 Oct, approved): a photo of you, four cards that build one entry, the start screen, nothing-found. The Score tip is gone. |
| `FLOW-BRIEF.md` | The shared brief for drawing a flow mockup. |

## Decisions (Eamon, 3 Oct 2026)

1. V1 is **Ate** (the journal in `docs/PRODUCT.md`), not the strategy doc's "Order".
2. Rebuild **in place**: keep `supabase/`, `AteKit/`, the design tokens. Rebuild the shell, screens, chrome.
3. **Keep the design system**; re-pattern each flow from Mobbin research; Eamon approves one mockup per flow.
4. **Native iOS 26 chrome everywhere**, never mixed with custom chrome. This replaces `docs/DESIGN.md`'s Chrome section.
5. The current build is **frozen**. No fixes, no cohort.
6. AI sorter spend approved. No social in V1. Voice is cut.
7. Threads merge and ship internal TestFlight on CI green plus QA. Updates per phase only.
8. Reseed staging with real photos, provenance-guarded.

## Pattern choices (Eamon, 3 Oct 2026)

- The composer is a sheet. Close is a glass disc top left, the primary action a glass disc top right, on every sheet.
- **+ is a tab**, in the bar's detached trailing slot. The tab bar stays on every pushed page.
- The selected tab is the quiet native state: no fill, no tint. + is the only coloured thing in the bar.
- The Journal's title is the wordmark. Feed, Search, You use their names.
- Filters are one button and one sheet on every list; chips show only while a filter is on.
- The Feed opens on your Journal city. Location is asked only on Near me or the place picker.
- Diet tags are a composer key beside Score and Place.

## Build rule: components first (Eamon, 3 Oct 2026)

"Ensure you are building things in a logical and atomic way." The flows were designed separately and the
mockups disagree in small ways about the same element. That must not reach the build.

- One component kit (tokens, atoms, composites) is built and checked once, in a Debug gallery on a phone, before any screen.
- Screens are arrangements of kit components plus data. No colour, font, radius, shadow or spacing literal outside `App/DesignSystem/`.
- Where mockups disagree, `pattern-contract.html` wins and the mockup is wrong. Mockups show layout and content only.
- `HISTORY-AUDIT.md` lists earlier rulings and build behaviours the mockups do not draw. The build and Eamon's feedback outrank `docs/DESIGN.md`.

## Phases

0 decisions (done) · 1 flow mockups from the contract (Journal, Feed, Browse, You in progress) and the
spec freeze · 2 skeleton · 3 flows built in parallel on disjoint files · 4 parity and cutover · 5 cohort.
