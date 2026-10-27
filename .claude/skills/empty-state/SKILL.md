---
name: empty-state
description: Make or change an Ate empty state (the Paper Trail drawing plus its one line). Use when a screen needs an empty, gone, or couldn't-reach state.
---

# Empty states

The rule is in `docs/DESIGN.md` (rule 4, "Empty states"). The parts, scenes and renderer are in
`design/illustrations/`. An empty state is one drawing, one line and at most one pill, built with
`AteEmptyState(line:art:pill:size:)`.

## 1. Pick the kind, and reuse one first

Choose the drawing by what the emptiness is, never by which screen it's on. The kinds are the
`AteEmptyArt` cases, and each `SCENES` entry in `kit.js` says what it means (`kind`):

journal (your record has nothing yet) · lists (no lists) · list (a list or pick with nothing on it) ·
saved (nothing kept for later) · rail (nobody has written here yet) · setting (nothing eaten here
yet) · bell (nothing new) · search (nothing matched) · unplugged (couldn't reach Ate, with a retry) ·
torn (it's gone) · photos (no meals in your photos).

If the situation already has a kind somewhere in the app, use the same drawing and the same words.
Most new screens need no new drawing.

## 2. Write the line

- One line in Young Serif 20 (`.emptyTitle`, smaller than every title). Break it with `\n` at most once, and end it with a full stop.
- Say literally what is there. Don't apologise, explain or add helper copy, and never invent a
  heading.
- Use at most one pill, starting with a verb ("Try again", "Add a dish"), and only when there is an
  action to take.
- Use the house lines when they fit: "Couldn't\nreach Ate." · "Nothing new." · "No dishes\nhere yet." ·
  "No dishes within 2 km." / "No dishes here." (the map sheet, with `.setting` at `.section`).

## 3. A new kind (only if none fits)

1. Compose it in `K.SCENES` from existing `PARTS`. Use one paper thing (docket world), one food
   thing (table world) and at most one wink. Ink only, objects only, never sad. Add a part to
   `PARTS` only if no existing part can say it, drawn with the house strokes (`marks`) and
   −35° hatching.
2. **Mockup first.** Publish the drawing at real device scale in light and dark, in its real screen,
   as a claude.ai Artifact. Send Eamon the link and wait for his explicit OK before building.
3. Render it into the asset catalogue:
   `NODE_PATH=$(npm root -g) node design/illustrations/render.js && python3 design/illustrations/split.py`
   This writes the `EmptyXInk` / `EmptyXPaper` template layers, trimmed top and bottom to what is
   drawn so the line sits right under it (12pt on a page, 8 in a section). The app tints them, so
   dark mode is automatic. Never hand-pad a drawing or add a spacer between it and the line.
4. Add the `AteEmptyArt` case, with its raw value equal to the scene's `asset`, and a one-line doc
   comment saying what the emptiness is.

## 4. Size and ship

- Use `.page` (160pt) when the state fills a page or sheet, and `.section` (96pt) when it sits
  inside a page (for example, a dish's reviews).
- Picture changes fail the snapshot tests. Put `[record-snapshots]` in the commit message so CI
  re-records them.
