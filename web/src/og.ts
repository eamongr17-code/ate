// web/src/og.ts — the link preview image for a post (1200 × 630 PNG, /entry/<id>/og.png).
//
// Option 1B of the 2 Nov mockup (dish-first): the post's first photo fills the card (thumbnail when
// there is one), darkened toward the bottom; the wordmark top-left; along the bottom the headline dish
// (top score, else the first), "@handle at Place" under it (+N more when there are other dishes), and
// the dish's score pill on the right. No photo → the same words in ink on the ground. Rendered with
// satori + resvg (workers-og); satori reads only TTF/OTF, so the fonts here are TTF.
//
// Every string goes through esc(): satori parses this HTML, so a dish name is text, never markup.

import { atLine, esc, headlineDish, type Card } from './render.ts';

const INK = '#24141F';
const MUTED = '#5E5560';
const GROUND = '#EFEAE2';
const BUTTER = '#F6D365';
const PAPER = '#FBF9F6';

// The star is drawn, not typed: DM Sans has no ★, so satori drew a missing-glyph box (3 Nov).
const STAR = `data:image/svg+xml;base64,${btoa(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="${INK}" d="M12 1.6l3.1 6.6 7.2.9-5.3 5 1.4 7.1L12 17.7l-6.4 3.5 1.4-7.1-5.3-5 7.2-.9z"/></svg>`)}`;

export interface OgParts {
  dish: string | null;
  score: string | null;
  byline: string;
  more: number;
}

/** What the image says, from the card — kept apart from the markup so it is easy to test. */
export function ogParts(card: Card): OgParts {
  const lead = headlineDish(card);
  const dishes = (card.items ?? []).filter((i) => i.dish_name).length;
  return {
    dish: lead?.name ?? null,
    score: lead && lead.score !== null ? lead.score.toFixed(1) : null,
    byline: atLine(card),
    more: Math.max(0, dishes - 1),
  };
}

/** `logos`: the wordmark in ink (no photo) and in paper (on the photo), as data URIs. */
export function ogHTML(parts: OgParts, photo: string | null, logos: { ink: string; paper: string }): string {
  const onPhoto = photo !== null;
  const fg = onPhoto ? PAPER : INK;
  const sub = onPhoto ? 'rgba(251,249,246,.86)' : MUTED;
  const back = onPhoto
    ? `<img src="${esc(photo)}" width="1200" height="630" style="position:absolute;left:0;top:0;width:1200px;height:630px;object-fit:cover">
  <div style="display:flex;position:absolute;left:0;top:0;width:1200px;height:630px;background-image:linear-gradient(180deg,rgba(20,10,16,0) 38%,rgba(20,10,16,.84) 100%)"></div>`
    : '';
  const byline = [parts.byline, parts.more > 0 ? `+${parts.more} more` : ''].filter(Boolean).join(' · ');
  const pill = parts.score
    ? `<div style="display:flex;flex-shrink:0;align-items:center;justify-content:center;height:84px;padding:0 30px;border-radius:999px;background:${BUTTER};color:${INK};font-family:'DM Sans';font-weight:700;font-size:48px"><img src="${STAR}" width="40" height="40" style="width:40px;height:40px;margin-right:12px">${esc(parts.score)}</div>`
    : '';
  return `<div style="display:flex;position:relative;width:1200px;height:630px;background:${GROUND};color:${fg}">
  ${back}
  <img src="${onPhoto ? logos.paper : logos.ink}" width="160" height="76" style="position:absolute;left:56px;top:46px;width:160px;height:76px">
  <div style="display:flex;position:absolute;left:56px;right:56px;bottom:52px;align-items:flex-end;justify-content:space-between">
    <div style="display:flex;flex-direction:column;flex:1;min-width:0;margin-right:28px">
      ${parts.dish ? `<div style="display:flex;font-family:'Young Serif';font-size:96px;line-height:1;letter-spacing:-2px">${esc(parts.dish)}</div>` : ''}
      <div style="display:flex;font-family:'DM Sans';font-weight:500;font-size:34px;color:${sub};margin-top:16px">${esc(byline)}</div>
    </div>
    ${pill}
  </div>
</div>`;
}
