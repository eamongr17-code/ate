// web/src/og.ts — the link preview image for a post (1200 × 630 PNG, /entry/<id>/og.png).
//
// Option A of the mockup: the post's first photo (thumbnail when there is one) on the left, tilted;
// the wordmark, the place, "@handle · locality" and up to three dishes with their scores on the right.
// No photo → the dishes run the full width. Rendered with satori + resvg (workers-og); satori reads
// only TTF/OTF, so the fonts here are TTF (DM Sans 500/700 static, Young Serif).
//
// Every string goes through esc(): satori parses this HTML, so a dish name is text, never markup.

import { esc, type Card } from './render.ts';

const INK = '#24141F';
const MUTED = '#5E5560';
const GROUND = '#EFEAE2';
const BUTTER = '#F6D365';
const HAIR = 'rgba(36,20,31,.14)';
const MAX_ROWS = 3;

export interface OgParts {
  place: string | null;
  byline: string;
  rows: { name: string; score: string | null; best: boolean }[];
  more: number;
}

/** What the image says, from the card — kept apart from the markup so it is easy to test. */
export function ogParts(card: Card): OgParts {
  const handle = card.author?.username ? `@${card.author.username}` : '';
  const byline = [handle, card.place?.locality ?? ''].filter(Boolean).join(' · ');
  const items = [...(card.items ?? [])].sort((a, b) => a.position - b.position);
  const best = Math.max(-1, ...items.map((i) => (typeof i.score === 'number' ? i.score : -1)));
  const rows = items.slice(0, MAX_ROWS).map((i) => ({
    name: i.dish_name,
    score: typeof i.score === 'number' ? i.score.toFixed(1) : null,
    best: typeof i.score === 'number' && i.score === best,
  }));
  return { place: card.place?.name ?? null, byline, rows, more: Math.max(0, items.length - MAX_ROWS) };
}

export function ogHTML(parts: OgParts, photo: string | null, logoDataURI: string): string {
  const left = photo ? 580 : 70;
  const photoHTML = photo
    ? `<img src="${esc(photo)}" width="470" height="542" style="position:absolute;left:44px;top:44px;width:470px;height:542px;object-fit:cover;border-radius:24px;border:6px solid #FBF9F6;transform:rotate(-3deg)">`
    : '';
  const rows = parts.rows.map((r, i) => `
    <div style="display:flex;justify-content:space-between;align-items:center;height:96px;border-top:${i === 0 ? '0' : `2px solid ${HAIR}`}">
      <div style="display:flex;flex:1;min-width:0;margin-right:16px;font-family:'Young Serif';font-size:46px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis">${esc(r.name)}</div>
      <div style="display:flex;align-items:center;justify-content:center;min-width:150px;height:68px;border-radius:999px;font-family:'DM Sans';font-weight:700;font-size:40px;${r.best ? `background:${BUTTER}` : `border:2px solid ${HAIR}`}">${r.score ? `★ ${r.score}` : ''}</div>
    </div>`).join('');
  const more = parts.more > 0
    ? `<div style="display:flex;font-family:'DM Sans';font-weight:500;font-size:30px;color:${MUTED};margin-top:10px">+${parts.more} more</div>`
    : '';
  return `<div style="display:flex;position:relative;width:1200px;height:630px;background:${GROUND};color:${INK}">
  ${photoHTML}
  <div style="display:flex;flex-direction:column;position:absolute;left:${left}px;right:60px;top:48px">
    <img src="${logoDataURI}" width="120" height="57" style="width:120px;height:57px">
    ${parts.place ? `<div style="display:flex;font-family:'Young Serif';font-size:84px;letter-spacing:-1.6px;margin-top:30px;line-height:1">${esc(parts.place)}</div>` : ''}
    ${parts.byline ? `<div style="display:flex;font-family:'DM Sans';font-weight:500;font-size:34px;color:${MUTED};margin:16px 0 20px">${esc(parts.byline)}</div>` : ''}
    <div style="display:flex;flex-direction:column">${rows}</div>
    ${more}
  </div>
</div>`;
}
