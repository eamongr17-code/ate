# Ate — design (V1)

Approved by Eamon 2026-09-22 after six review rounds. **You bring the mess. We print the receipt.**

Source of truth is `design/v1/` — one `.dc.html` per screen (the approved prototype's markup: read it
for exact sizes, colours, radii and copy; it is 390×844 and does not render outside its canvas).
`/_blob/…` URLs in it are canvas-hosted photos; ignore them. This file is the summary and the rules.

## Rules Eamon set (do not regress)

1. **Minimal.** Icons before labels. No helper captions, hints or explanatory micro-copy. Ever.
2. **No " · " dot separators.** Put the two values left and right, or drop one.
3. **Two shapes only.** Pills (999) for controls: tab bar, buttons, chips, fields, segments. 16pt for
   receipt tops and photos. Everything else has no container — plain rows with a hairline.
4. **Receipts are what Ate prints** (white paper, mono type, dashed rules, dot leaders, torn bottom
   edge, 16pt rounded top). Use one only where something was printed from the user's words.
   The receipt is the **share** artefact and lives in `Share` alone — `Entry` is a page, not a receipt.
5. **Colour is punctuation**, never decoration: score tokens, avatars, the + button, Share/Welcome
   grounds. No blobs, patterns, gradients-as-style, or colour-blocked feed cards.
6. **The mess is tilt + overlap of photos**, only in small static clusters (entry, dish hero, share,
   welcome). Anything in a scrolling list is straight and evenly spaced.
7. **Scores are only ever the user's.** Never inferred. Unscored dish = an empty star, no text.
   Stars are never low-opacity: solid outline, half = half-filled. Aggregates show to the nearest half.
   Scoring is a finger **slide**, not taps. Scores print like prices: right-aligned, one decimal.
8. **A place is only attached when the user names it or taps it.** Never from location alone.
9. **The user's words are saved instantly and never rewritten.** The sorter only adds structure.
10. Lists and receipts that continue run off the bottom of the screen; content fades under the tab bar.
11. The logo is the supplied wordmark, never typeset.

## Tokens

| | Light (default) | Dark |
|---|---|---|
| ground | `#EFEAE2` linen | `#17111B` ink |
| text / fg | `#24141F` | `#FFFFFF` |
| muted | `#5E5560` | `#B9AFBC` |
| chip / control surface | `#FFFFFF` | `#2B2231` |
| field | `#E4DED4` | `#2B2231` |
| hairline | fg @ 14% | white @ 16% |
| receipt paper | `#FFFFFF` | `#E6DFD3` (dimmed; text on paper stays `#24141F`) |

Accents (same in both modes, always carry `#24141F` text): coral `#F0623F` · butter `#F6D365`
(score token, histogram) · green `#3ECF64` · pink `#F490D4` · sky `#36AEE6` · lilac `#B9A5EA`.
Destructive `#B3261E`.

Type — three voices, bundled fonts (all OFL):
- **Bricolage Grotesque** — titles (800, tracking −3.5%, line-height 1.0) and controls/labels (600, 15; meta 500, 13).
- **Newsreader** — the user's words, everywhere they appear (16–19, line-height 1.45–1.5; italic for quoted dish notes).
- **DM Mono** — only inside receipts (line items 13; labels 11 uppercase, tracking 8%).

Spacing: screen gutter 20; content top 60–70 under the status bar; 44pt minimum hit targets.
Motion (all gated on Reduce Motion): receipt prints in (slide 24pt + fade, 0.6s); caret blink; voice
pulse; score numerals roll.

## Components

- **Tab bar** — one floating white pill, 66 high: Journal · Feed · **+** (54 ink circle) · Search · You.
  Icon + 10.5pt label; active = fg + bold, inactive = muted. Content fades to ground beneath it.
- **Score token** — butter pill, filled star + one-decimal number, DM Mono 500, inline in prose.
- **Place token** — field-coloured pill, pin + name, Bricolage 600, inline in prose.
- **Receipt** — place (title 32) + address (mono label) / dashed rule / numbered line items with dot
  leaders and right-aligned score, each dish's note in Newsreader italic beneath it / dashed rule /
  `Order #` left, date right; `n dishes` left, `Avg` right / barcode / handle left, logo right / torn edge.
- **Journal slip** — place title + visibility icon (globe/lock), words (3-line clamp, inline tokens),
  tilted 80pt photo cluster, dashed rule, line items. Feed slip = the same + byline row (avatar,
  handle, age, bookmark) and an 84pt straight thumbnail beside two lines of words; ≤2 line items.
- **Sheets** (place / dish / new place / actions) — white, 32pt top corners, grabber, title 30, pill
  search field, radio rows, one ink pill button.
- **Photo** — squircle (radius 28% of side; 16 on thumbs), 3pt ring in the surface colour when overlapping.

## Screens (`design/v1/<name>.dc.html`)

Journal & compose: `Main` (Journal | Saved segment; logo; photo-stack button with count) · `MainEmpty` ·
`Suggestions` (photos to write up; never guesses a place) · `Saved` (grouped by place) · `Composer` ·
`ComposerStars` (slide to score) · `ComposerVoice` · `Entry` (one white page on the linen ground, 24pt
top corners, running off the bottom: `Order #` / date mono row, place title 38, tilted photo collage,
the words with their tokens, dashed rule, the bill (line items only — no notes), dashed rule, address /
`Avg`. No receipt here; title → `PlaceSheet`, line → `DishSheet`, photo → full-screen viewer) ·
`PlaceSheet` · `AddPlace` · `DishSheet`.
Gives back: `You` · `Ratings` (tap a histogram bar) · `Recap` (monthly statement) · `Share` · `Settings`.
Everyone else: `Feed` · `Profile` · `Actions` (save/share/report/block) · `Restaurant` · `Dish` · `Search` · `SearchResults`.
First run: `Welcome` · `Handle`. Dark mode samples: `MainInk` · `FeedInk` · `EntryInk`. Parked: `Ask`.

Composer toolbar: camera · library · mic | **Score** (butter) · **Place** (field) | globe (public/private).
Typing a number after a dish, or saying one, becomes the same score token.

## Not drawn — build with the existing vocabulary

Offline / not-yet-sorted entry (words show, the bill absent) · loading (skeletons of the real
components, never a spinner for first load) · someone else's entry (= `Entry` with a byline and a
bookmark instead of edit/visibility) · system photo picker and keyboard.
