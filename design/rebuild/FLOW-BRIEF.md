# Flow mockup brief (shared by every flow)

You are producing ONE HTML mockup page for one flow of the Ate iOS app rebuild. Eamon (non-technical co-founder, brand owner) approves it. No app code is touched.

## Read first, in this order
1. `design/rebuild/pattern-contract.html` — THE CONTRACT. Every rule in it is binding. Never re-decide anything it settles.
2. `design/rebuild/compose-entry.html` — the APPROVED Compose mockup. Copy its visual kit exactly: the `<style>` block (phone frame `.ph/.scr`, `.glass`, `.disc`, `.tok`, `.diet`, `.dish`, `.tabbar` + `.plusdisc`, `.kbd`, `.receipt`, fonts, tokens, brief tables) and its `<script>` (inline Lucide-style icons via `data-i`, the `fit()` scaler). Your page must look like it was drawn by the same hand. Add icons to the `P` map when you need new ones (keep Lucide shapes).
3. `docs/DESIGN.md` and `docs/PRODUCT.md`.
4. Your flow's `design/v1/*.dc.html` files under `design/v1/` (listed per flow below). They are the approved content and layout of each screen; keep the slip anatomy, receipt, score token, letter tile, tag chips, photo clusters exactly. Only the CHROME changes (to native, per the contract).

## Research
Use the Mobbin MCP tools (`mcp__mobbin__search_screens`, `mcp__mobbin__search_flows`, platform ios, mode "standard", limit ≤6 per query, output_destination "doc", task_intent "Redesign the <flow> flow of a dish journal app with native iOS 26 chrome") for 3–5 targeted queries. Cite 1–3 Mobbin links per screen in the brief table. Do not paste images into the page.

## Hard rules (from Eamon)
- Native iOS 26 chrome everywhere: native tab bar (4 tabs + the coral + disc in the detached trailing slot, selected tab = quiet glass highlight, NO fill), native large title collapsing to inline on scroll, controls in ONE trailing glass group (≤3 icons), pushed pages use the inline native bar with a glass back disc. Tab bar stays on every pushed page.
- Sheets: native, grabber, close glass disc top-LEFT, primary action glass disc top-RIGHT; a sheet that applies a choice ends in one ink pill with a live count; a sheet that picks a row closes on tap.
- Filters: one filter icon → one sheet; chips under the bar only while a filter is on.
- Minimal: no helper copy, no eyebrow/kicker text, no big CTAs, no " · " separators, icons before labels. Two shapes only (pills for controls, 16pt for slips/photos). Colour is punctuation. Unrated dish = empty slot. Place never from location. No social (Save is the only action). No voice.
- Photos are colour stand-ins (`.food1/.food2/.food3` gradients), never real images.

## Deliverable
Write ONE file: `design/rebuild/<flow>.html` (no doctype/html/head/body tags; start with `<title>` like compose.html does). Structure, same as compose.html:
1. `<title>` (2–4 words, the flow's name) + header with a one-line lede.
2. "The mockup": 5–8 phone screens (`.cell` > `.ph` > `.scr`), each with an h3 and one sentence.
3. "Screens and patterns" table: screen · pattern · best-in-class Mobbin links.
4. "What changes from the current build" (bullets, why).
5. "Native iOS 26 parts" table (SwiftUI pieces).
6. "Decided" (what the contract already fixes) and "Your call" — AT MOST TWO one-word choices for Eamon, recommended first, only if genuinely his (taste or product), never something the contract or design already answers. Zero is fine.
Do NOT publish anything, do NOT post to any thread, do NOT call any `mcp__hearthbot__` tool. Do not touch the repo. When done, reply with: the file path, the screen list, and your "Your call" items (or "none").
