# Ate — design (V1)

Approved by Eamon 2026-09-22 after six review rounds; the dish-first card round approved 2026-09-25.
**You bring the mess. We print the receipt.**

Source of truth is `design/v1/` — one `.dc.html` per screen (the approved prototype's markup: read it
for exact sizes, colours, radii and copy; it is 390×844 and does not render outside its canvas).
`/_blob/…` URLs in it are canvas-hosted photos; ignore them. This file is the summary and the rules.

## Rules Eamon set (do not regress)

1. **Minimal.** Icons before labels. No helper captions, hints or explanatory micro-copy. Ever.
2. **No " · " dot separators.** Put the two values left and right, or drop one.
3. **Two shapes only.** Pills (999) for controls: tab bar, buttons, chips, fields, segments. 16pt for
   slips, receipt tops and photos. Everything else has no container — plain rows with a hairline.
4. **Receipts are what Ate prints** (white paper, mono type, dashed rules, dot leaders, torn bottom
   edge, 16pt rounded top). Use one only where something was printed from the user's words.
   The receipt is the **share** artefact and lives in `Share` alone — `Entry` is a page, not a receipt.
   **Tears on dish entry slips and the place menu only** (the stats slip on You/Profile is whole,
   16 all round; receipts that print — Share, the statement — keep theirs).
   **Empty states use no receipt motif**: one 40pt line and at most one ink pill, on the ground.
5. **Colour is punctuation**, never decoration: score tokens, avatars, the + button, Share/Welcome
   grounds. No blobs, patterns, gradients-as-style, or colour-blocked feed cards.
6. **The mess is tilt + overlap of photos**, only in small static clusters (entry slips, entry,
   dish hero, share, welcome, `Suggestions` rows). Thumbnails elsewhere in a list are straight.
7. **Scores are only ever the user's.** Never inferred. **An unrated dish is an empty score slot
   everywhere** — cards, the Entry bill, Share and statement receipts (the dot leader runs to the
   edge), Place, Dish, Search and Saved rows: no star, no mark, no text, no zero.
   Stars are never low-opacity: solid outline, half = half-filled. Aggregates show to the nearest half.
   Scoring is a finger **slide**, not taps. Scores print like prices: right-aligned, one decimal.
8. **A place is only attached when the user names it or taps it.** Never from location alone.
9. **The user's words are saved instantly and never rewritten.** The sorter only adds structure.
10. Lists and receipts that continue run off the bottom of the screen; content fades under the tab bar.
11. The logo is the supplied wordmark, never typeset.
12. **Public/private no longer exists.** Every entry is public; no globe or lock anywhere.

## Tokens

| | Light (default) | Dark |
|---|---|---|
| ground | `#EFEAE2` linen | `#17111B` ink |
| text / fg | `#24141F` | `#F4EFE9` |
| muted | `#5E5560` | `#B9AFBC` |
| chip / control surface | `#FFFFFF` | `#342A3A` |
| field | `#E4DED4` | `#231B24` |
| hairline | fg @ 14% | white @ 16% |
| slip (cards, Entry page, statement, on-screen Share receipt) | `#FFFFFF`, ink text | `#231B24`, `#F4EFE9` text, `#B9AFBC` muted; chip/field `#342A3A`, hairline white @ 12%, rules white @ 22%; tear in slip colour. The exported share image stays light |
| receipt paper (place menu, Welcome) | `#FFFFFF` | `#E6DFD3` (dimmed; text on it stays `#24141F`) |

Accents (same in both modes, always carry `#24141F` text): coral `#F0623F` · butter `#F6D365`
(score token, histogram) · green `#3ECF64` · pink `#F490D4` · sky `#36AEE6` · lilac `#B9A5EA`.
Destructive `#B3261E`.

Type — three voices, bundled fonts (all OFL):
- **Bricolage Grotesque** — titles (800, tracking −3.5%, line-height 1.0) and controls/labels (600, 15; meta 500, 13).
- **Newsreader** — the user's words, everywhere they appear (16–19, line-height 1.45–1.5; italic for quoted dish notes).
- **DM Mono** — only inside receipts (line items 13; labels 11 uppercase, tracking 8%).

Spacing: screen gutter 20; **list gutter 12** (Journal, Feed, Profile: slips and their headers);
content top 60–70 under the status bar; 44pt minimum hit targets.
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
- **Entry slip** — ONE card anatomy for the Journal, Feed and Profile. Feed opens with a byline row
  (28pt avatar, handle — truncates — and age); Journal and Profile have no top row. Then the **dish
  rows**: name (`.h` 20/21) left, score (`.h` 26 with a filled 16 star) right, 1pt hairline between,
  44 minimum; a long name wraps to 2 lines then ellipsis, score top-aligned to its first line; unrated
  = empty slot. Then the words (16, 2-line clamp, inline tokens) — **Feed hides them when a visit has
  more than 2 dishes** — then the tilted 80pt photo cluster, then the **foot line**: muted pin + place
  (600, 14) + suburb (muted 13), and the Journal's date ("Sat 19 Sep") or a Profile's age right-aligned.
  The place truncates first; suburb and date never wrap. In the feed and on a profile every dish row
  carries its own bookmark: a save is always one dish, never a whole entry.
- **Sheets** (place / dish / new place / actions) — white, 32pt top corners, grabber, title 30, pill
  search field, radio rows, one ink pill button.
- **Photo** — squircle (radius 28% of side; 16 on thumbs), 3pt ring in the surface colour when overlapping.

## Screens (`design/v1/<name>.dc.html`)

Journal & compose: `Main` (Journal | Saved segment; logo; photo-stack button with count; no day
headers) · `JournalLong` + `FeedLong` (long names, long places) · `MainEmpty` ·
`Suggestions` (photos to write up as tilted 88pt clusters; never guesses a place) · `Saved` (grouped by place) · `Composer` ·
`ComposerStars` (slide to score) · `ComposerVoice` · `Entry` (one white page on the linen ground, 24pt
top corners, running off the bottom: `Order #` / date mono row, place title 38, tilted photo collage,
the words with their tokens, dashed rule, the bill (line items only — no notes), dashed rule, address /
`Avg`; a date, never a time. No receipt here; title → `PlaceSheet`, line → `DishSheet`, photo → full-screen viewer) ·
`PlaceSheet` · `AddPlace` · `DishSheet`.
Gives back: `You` · `Ratings` (tap a histogram bar) · `Recap` (monthly statement) · `Share` · `Settings`.
Everyone else: `Feed` · `Profile` · `Actions` (save/share/report/block) · `Restaurant` · `Dish` · `Search` · `SearchResults`.
First run: `Welcome` · `Handle`. Dark mode samples: `MainInk` · `FeedInk` · `EntryInk`. Parked: `Ask`.

Composer toolbar: camera · library · mic | **Score** (butter) · **Place** (field).
Typing a number after a dish, or saying one, becomes the same score token.

## Not drawn — build with the existing vocabulary

Offline / not-yet-sorted entry (words show, the bill absent) · loading (skeletons of the real
components, never a spinner for first load) · someone else's entry (= `Entry` with a byline and a
bookmark instead of edit) · system photo picker and keyboard.
