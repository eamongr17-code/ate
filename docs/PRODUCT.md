# Ate — product brief (re-ratified 2026-09-22, CEO direction — Eamon)

**You bring the mess. We print the receipt.** Ate is a food journal you keep for yourself, written
the way you'd text a friend. Ate turns those words into a receipt — the place, the dishes, the scores
you gave — and the receipts of everyone who loves food become the answer to **"what should I order
here?"** Brand strategy: `docs/BRAND.md`. Approved design: `docs/DESIGN.md` + `design/v1/`.

**The dish is still the atom.** Nobody eats a restaurant. But the thing a person *makes* is an
**entry**: one visit, in their own words, with photos. Dishes, scores and the place are structure Ate
adds underneath. The flywheel:
**writing an entry is a pleasure in itself → every entry feeds your journal, your taste, and the
public record → shared receipts and saved dishes pull people in and back → dish density accumulates
per restaurant → the ranked menu becomes the reason everyone else installs.**

## For
New Age Foodies (see BRAND.md) in Melbourne, starting with an invited cohort of 20–50. iPhone only.
**Density beats breadth**: one city until won.

## What it is — the decisions that define V1
1. **A private-feeling journal first** (the Letterboxd model): you write for yourself; entries are
   **public by default** with your byline, and any entry can be private. The journal is home; the
   feed is a place you visit.
2. **Natural language is the input.** One composer — typing, voice and photos feed the same entry;
   no structured form. It must work at the table, right after, and days later from your camera roll.
3. **Your words save instantly and are never rewritten.** A sorter adds structure quietly underneath
   (place, dishes, each dish's note); every piece is tappable to fix. Nothing blocks saving.
4. **Scores are only ever yours**, and they live *inside* the writing: type or say a number, or use
   the Score key and slide. Never inferred. An unscored dish simply has no score.
5. **A place is attached only when you name it or tap it** — never from location alone. The place is
   an inline token, like the score.
6. **Venues only.** Every entry is about eating out.
7. **The feed exists for one reason: deciding where to eat next.** So its one action is **Save**
   (no likes, comments or follows), and Saved lives beside your journal.
8. **Four payoffs, all in V1:** recall (your journal, search), your taste reflected (ratings,
   5.0s, monthly statement), better ordering (place and dish pages), beautiful artefacts (the receipt).

## V1 surfaces
Journal | Saved · Composer (write, slide-to-score, voice, place) · Entry (your words + the receipt) ·
Feed · Place ("what to order") · Dish · Search · You (taste, ratings by score, monthly statement,
share) · profiles · settings, report and block · Sign in with Apple + handle. Light and dark.
Parked: ask-your-journal, at-the-table browse, follows/comments/notifications, city #2, Android.

**Build order:** milestone 1 is the core loop — write → score/place inline → receipt prints → it's in
your journal (sorter stubbed until AI spend is approved). Milestone 2 is everything else.

## Metrics
- **North star: dishes logged per weekly active user.**
- Entry friction: median seconds from `+` to Done. Sorter quality: share of receipts the user edits.
- Loop: saves per feed session; saved dishes later eaten; share rate; receipt-attributed installs.
- Density tripwire for leaning on the ranked menu: ~40% of place pages viewed have ≥3 scored dishes.
- **Anti-metrics** (never optimise, never celebrate): registered users, time-in-feed.

The strategy is falsified if people install, browse, and don't write — then we rebuild the composer,
not the feature set.

## Principles that decide arguments
1. The dish is the atom of the data; the entry is the atom of the experience.
2. The user's words are sacred. Ate adds structure; it never edits, guesses a score, or assumes a place.
3. Say less: icons before labels, no helper copy. If it needs explaining, redesign it.
4. Thirty seconds, one hand, mid-meal.
5. Good with one user in one city — nothing may depend on scale to be worth using.
6. The receipt is the marketing — every entry ends in an artefact worth posting.
7. Brand is Made to Order (BRAND.md), expressed through the design system — no longer deferred.
