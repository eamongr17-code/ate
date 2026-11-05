// web/src/render.ts — the pages and the AASA (pure, tested by test/index.test.ts). index.ts routes.

const CACHE_SECONDS = 300;

export interface Env {
  SUPABASE_URL: string;
  SUPABASE_PUBLISHABLE_KEY: string;
  APP_LINK: string;
  APP_ID: string;
}

// ─── Universal links ────────────────────────────────────────────────────────────────────────────

export function aasa(appID: string) {
  return {
    applinks: {
      details: [{
        appIDs: [appID],
        components: [
          { '/': '/entry/*', comment: 'A shared post' },
          { '/': '/list/*', comment: 'A shared list' },
        ],
      }],
    },
  };
}

// ─── The post ───────────────────────────────────────────────────────────────────────────────────

export interface Card {
  id: string;
  created_at: string;
  body: string | null;
  author: { username: string | null } | null;
  place: { name: string; locality: string | null } | null;
  photos: { url: string; position: number }[] | null;
  items: { dish_name: string; score: number | null; position: number }[] | null;
}

/** The post, as the signed-out Feed reads it. null = not there (deleted, blocked); throws on an outage. */
export async function fetchCard(id: string, env: Env): Promise<Card | null> {
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/get_entry_card`, {
    method: 'POST',
    headers: {
      apikey: env.SUPABASE_PUBLISHABLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_PUBLISHABLE_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ p_entry_id: id }),
    signal: AbortSignal.timeout(5000),
  });
  if (res.ok) return parseCard(await res.json());
  if (res.status >= 500) throw new Error(`get_entry_card ${res.status}`);
  return null;
}

export async function entryPage(id: string, origin: string, env: Env): Promise<Response> {
  let card: Card | null;
  try {
    card = await fetchCard(id, env);
  } catch {
    return errorPage(origin, env);
  }
  if (!card) return gonePage(origin, env);
  return html(renderEntry(card, origin, env, `${origin}/entry/${card.id}/og.png`), 200);
}

/** The photo for the preview image: the first photo's thumbnail when it exists, else the photo, else none. */
export async function previewPhoto(card: Card): Promise<string | null> {
  const first = firstPhoto(card);
  return first ? await thumbnailIfThere(first) : null;
}

/** get_entry_card answers one row, an array of one, or null; anything else is "not there". */
export function parseCard(raw: unknown): Card | null {
  const row = Array.isArray(raw) ? raw[0] : raw;
  if (!row || typeof row !== 'object' || typeof (row as Card).id !== 'string') return null;
  return row as Card;
}

function firstPhoto(card: Card): string | null {
  return [...(card.photos ?? [])].sort((a, b) => a.position - b.position).find((p) => isHttps(p.url))?.url ?? null;
}

/** The preview image: the photo's thumbnail (`<name>_t.jpg`, uploads since round 3) when it exists, so a
 *  chat preview does not pull the full-size photo; older photos have none → the full photo. */
export function thumbnailURL(url: string): string | null {
  const thumb = url.replace(/\.(jpe?g|png|heic|webp)(\?.*)?$/i, '_t.jpg');
  return thumb === url ? null : thumb;
}

async function thumbnailIfThere(url: string): Promise<string> {
  const thumb = thumbnailURL(url);
  if (!thumb) return url;
  try {
    const res = await fetch(thumb, { method: 'HEAD', signal: AbortSignal.timeout(2000) });
    return res.ok ? thumb : url;
  } catch {
    return url;
  }
}

/** The dish a share leads with (dish-first): the top score, the first of a tie; with no scores, the first dish. */
export function headlineDish(card: Card): { name: string; score: number | null } | null {
  const items = [...(card.items ?? [])].sort((a, b) => a.position - b.position).filter((i) => i.dish_name);
  if (!items.length) return null;
  const scored = items.filter((i) => typeof i.score === 'number');
  const top = scored.length ? scored.reduce((a, b) => ((b.score as number) > (a.score as number) ? b : a)) : items[0];
  return { name: top.dish_name, score: typeof top.score === 'number' ? top.score : null };
}

/** "@handle at Place" — the line under the dish (dish-first: the place is never the headline). */
export function atLine(card: Card): string {
  const handle = card.author?.username ? `@${card.author.username}` : '';
  const place = card.place?.name ?? '';
  return [handle, place].filter(Boolean).join(' at ') || 'Ate';
}

export function renderEntry(card: Card, origin: string, env: Env, previewImage: string | null = null): string {
  const handle = card.author?.username ? `@${card.author.username}` : 'Someone';
  const placeName = card.place?.name ?? null;
  const lead = headlineDish(card);
  const title = lead ? `${lead.name}${lead.score === null ? '' : ` ★ ${lead.score.toFixed(1)}`}` : atLine(card);
  const photos = [...(card.photos ?? [])].sort((a, b) => a.position - b.position).filter((p) => isHttps(p.url));
  const items = [...(card.items ?? [])].sort((a, b) => a.position - b.position);
  const best = Math.max(-1, ...items.map((i) => (typeof i.score === 'number' ? i.score : -1)));
  const appURL = `ate://entry/${card.id}`;

  // 2 Nov (Eamon, mockup 2): the photo near full width at 4:5, untilted; more than one swipes sideways.
  const photoHTML = photos.length
    ? `<div class="photos">${photos.map((p, n) =>
        `<img src="${attr(p.url)}" alt="" loading="${n ? 'lazy' : 'eager'}">`).join('')}</div>`
    : '';
  // The dishes are the headline, each at the same size, in the order they were rated; the place is a
  // line under the first.
  const rows = items.map((i) => {
    const scored = typeof i.score === 'number';
    const cls = scored && i.score === best ? 'sc best' : 'sc';
    const score = scored ? `${STAR}${(i.score as number).toFixed(1)}` : '';
    return `<div class="drow"><h1 class="dn">${text(i.dish_name)}</h1><span class="${cls}">${score}</span></div>`;
  });
  const at = placeName
    ? `<p class="at">at <b>${text(placeName)}</b>${card.place?.locality ? ` · ${text(card.place.locality)}` : ''}</p>`
    : '';

  return page({
    title,
    description: atLine(card),
    image: previewImage ?? photos[0]?.url ?? null,
    canonical: `${origin}/entry/${card.id}`,
    appURL,
    env,
    body: `${photoHTML}
<article>
  ${rows[0] ?? ''}
  ${at}
  ${rows.slice(1).join('')}
  ${card.body ? `<p class="words">${text(card.body)}</p>` : ''}
  <div class="byline"><span class="av">${text(initial(card.author?.username))}</span><b>${text(handle)}</b><span>· ${text(shortDate(card.created_at))}</span></div>
</article>`,
  });
}

// ─── The list, the gone page, the error page ────────────────────────────────────────────────────

export function listPage(id: string, origin: string, env: Env): Response {
  return html(page({
    title: 'A list on Ate', description: '', image: null, canonical: `${origin}/list/${id}`,
    appURL: `ate://list/${id}`, env, body: '',
  }), 200);
}

function gonePage(origin: string, env: Env): Response {
  return html(page({
    title: 'Ate', description: '', image: null, canonical: origin, appURL: null, env,
    body: '<p class="gone">This post was deleted.</p>',
  }), 404);
}

function errorPage(origin: string, env: Env): Response {
  return html(page({
    title: 'Ate', description: '', image: null, canonical: origin, appURL: null, env,
    body: '<p class="gone">This post didn’t load. Try again in a minute.</p>',
  }), 503);
}

// ─── The privacy policy and the terms ──────────────────────────────────────────────────────────
// legal/privacy.md and legal/terms.md, bundled at deploy, so the public links (TestFlight, the App
// Store) live on Ate's own domain rather than in the repo. The app shows the same words (LegalDocument).

/** The small Markdown the two documents use: `#`/`##` headings, `- ` bullets, paragraphs, **bold**, _italic_. */
export function legalHTML(markdown: string): string {
  const inline = (s: string) => text(s)
    .replace(/\*\*(.+?)\*\*/g, '<b>$1</b>')
    .replace(/(^|[\s(])_(.+?)_(?=$|[\s).,;:])/g, '$1<i>$2</i>');
  const out: string[] = [];
  let list = false;
  for (const raw of markdown.split('\n')) {
    const line = raw.trim();
    const bullet = line.startsWith('- ');
    if (list && !bullet) { out.push('</ul>'); list = false; }
    if (!line) continue;
    if (line.startsWith('## ')) out.push(`<h2>${inline(line.slice(3))}</h2>`);
    else if (line.startsWith('# ')) out.push(`<h1>${inline(line.slice(2))}</h1>`);
    else if (bullet) {
      if (!list) { out.push('<ul>'); list = true; }
      out.push(`<li>${inline(line.slice(2))}</li>`);
    } else out.push(`<p>${inline(line)}</p>`);
  }
  if (list) out.push('</ul>');
  return out.join('\n');
}

/** `/privacy` and `/terms`: the document on the site's own page. */
export function legalPage(markdown: string, path: string, origin: string, env: Env): Response {
  const heading = /^# (.+)$/m.exec(markdown)?.[1] ?? 'Ate';
  return html(page({
    title: heading, description: '', image: null, canonical: `${origin}${path}`, appURL: null, env,
    body: `<article class="legal">${legalHTML(markdown)}</article>`,
  }), 200);
}

// ─── The page shell ─────────────────────────────────────────────────────────────────────────────

interface PageParts {
  title: string; description: string; image: string | null; canonical: string;
  appURL: string | null; env: Env; body: string;
}

function page(p: PageParts): string {
  const og = [
    `<meta property="og:site_name" content="Ate">`,
    `<meta property="og:title" content="${attr(p.title)}">`,
    p.description ? `<meta property="og:description" content="${attr(p.description)}">` : '',
    `<meta property="og:url" content="${attr(p.canonical)}">`,
    `<meta property="og:type" content="article">`,
    p.image ? `<meta property="og:image" content="${attr(p.image)}">` : '',
    p.image && p.image.endsWith('/og.png') ? `<meta property="og:image:width" content="1200">\n<meta property="og:image:height" content="630">` : '',
    `<meta name="twitter:card" content="${p.image ? 'summary_large_image' : 'summary'}">`,
  ].filter(Boolean).join('\n');
  // "Open in Ate": tries the app's own scheme, and if the page is still here a moment later (no app),
  // goes to the App link. The plain href is the App link, so it works with scripts off too.
  const open = `<a class="open" href="${attr(p.env.APP_LINK)}"${p.appURL ? ` data-app="${attr(p.appURL)}"` : ''}>Open in Ate</a>`;
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${text(p.title)}</title>
<link rel="canonical" href="${attr(p.canonical)}">
${og}
<meta name="robots" content="noindex">
<link rel="preload" href="/fonts/youngserif.woff2" as="font" type="font/woff2" crossorigin>
<style>${CSS}</style>
</head><body>
<header><img class="logo" src="/logo.svg" alt="ate.">${p.body ? open : ''}</header>
<main>${p.body}${p.body ? '' : `<div class="solo">${open}</div>`}</main>
<script>${SCRIPT}</script>
</body></html>`;
}

const SCRIPT = `document.querySelectorAll('a[data-app]').forEach(function(a){a.addEventListener('click',function(e){e.preventDefault();var t=setTimeout(function(){location.href=a.href},1200);document.addEventListener('visibilitychange',function(){if(document.hidden)clearTimeout(t)},{once:true});location.href=a.dataset.app})})`;

const STAR = '<svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><path fill="currentColor" d="M12 2l3.1 6.3 6.9 1-5 4.9 1.2 6.8L12 17.8 5.8 21l1.2-6.8-5-4.9 6.9-1z"/></svg>';

const CSS = `
@font-face{font-family:'Young Serif';font-weight:400;font-display:swap;src:url(/fonts/youngserif.woff2) format('woff2')}
@font-face{font-family:'DM Sans';font-weight:100 1000;font-display:swap;src:url(/fonts/dmsans.woff2) format('woff2')}
@font-face{font-family:Newsreader;font-weight:200 800;font-display:swap;src:url(/fonts/newsreader.woff2) format('woff2')}
:root{--g:#EFEAE2;--ink:#24141F;--mut:#5E5560;--hr:rgba(36,20,31,.14);color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{--g:#17111B;--ink:#F4EFE9;--mut:#B9AFBC;--hr:rgba(255,255,255,.16)}.logo{filter:invert(1)}}
*{box-sizing:border-box}
body{margin:0;background:var(--g);color:var(--ink);font:400 18px/1.5 Newsreader,Georgia,serif;-webkit-text-size-adjust:100%}
header{display:flex;align-items:center;justify-content:space-between;max-width:560px;margin:0 auto;padding:14px 16px 10px}
.logo{height:30px;width:auto}
.open{display:inline-flex;align-items:center;height:40px;padding:0 18px;border-radius:999px;background:var(--ink);color:var(--g);font:600 15px/1 'DM Sans',sans-serif;text-decoration:none}
main{max-width:560px;margin:0 auto;padding:0 8px 48px}
.photos{display:flex;gap:8px;overflow-x:auto;scroll-snap-type:x mandatory;scrollbar-width:none;margin:4px 0 0}
.photos::-webkit-scrollbar{display:none}
.photos img{flex:0 0 100%;width:100%;aspect-ratio:4/5;object-fit:cover;border-radius:22px;scroll-snap-align:center}
article{padding:18px 10px 0;display:flex;flex-direction:column;gap:12px}
.byline{display:flex;align-items:center;gap:7px;margin-top:4px;font:500 14px/1 'DM Sans',sans-serif;color:var(--mut)}
.byline b{color:var(--ink);font-weight:600}
.av{width:26px;height:26px;border-radius:50%;background:#F6D365;color:#24141F;display:inline-flex;align-items:center;justify-content:center;font:700 13px 'DM Sans',sans-serif}
.at{margin:0;font:500 15px/1.3 'DM Sans',sans-serif;color:var(--mut)}
.at b{color:var(--ink);font-weight:600}
.words{margin:0;white-space:pre-wrap}
.drow{display:flex;justify-content:space-between;align-items:flex-start;gap:12px}
.dn{margin:0;font:400 34px/1.02 'Young Serif',Georgia,serif;letter-spacing:-.02em;text-wrap:balance}
.sc{flex-shrink:0;min-width:80px;height:38px;margin-top:1px;border-radius:999px;box-shadow:inset 0 0 0 1px var(--hr);display:inline-flex;align-items:center;justify-content:center;gap:4px;font:700 20px/1 'DM Sans',sans-serif}
.sc.best{background:#F6D365;color:#24141F;box-shadow:none}
.gone{margin:30vh 0 0;text-align:center;font:400 20px/1.25 'Young Serif',Georgia,serif}
.solo{margin-top:30vh;display:flex;justify-content:center}
.legal{gap:0;padding-bottom:24px}
.legal h1{margin:8px 0 6px;font:400 30px/1.1 'Young Serif',Georgia,serif;letter-spacing:-.01em}
.legal h2{margin:22px 0 6px;font:600 17px/1.3 'DM Sans',sans-serif}
.legal p{margin:0 0 10px}
.legal ul{margin:0 0 10px;padding-left:22px}
.legal li{margin:0 0 6px}
`;

// ─── Helpers ────────────────────────────────────────────────────────────────────────────────────

function html(body: string, status: number): Response {
  return new Response(body, {
    status,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': status === 200 ? `public, max-age=${CACHE_SECONDS}` : 'no-store',
      'Content-Security-Policy': "default-src 'none'; img-src 'self' https:; style-src 'unsafe-inline'; font-src 'self'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'strict-origin-when-cross-origin',
    },
  });
}

export function json(value: unknown): Response {
  return new Response(JSON.stringify(value), {
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=3600' },
  });
}

export function text(s: string | null | undefined): string {
  return (s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);
}
const attr = text;
export const esc = text;

function isHttps(u: string | null | undefined): u is string {
  try { return new URL(u ?? '').protocol === 'https:'; } catch { return false; }
}

function initial(username: string | null | undefined): string {
  return (username ?? '?').charAt(0).toUpperCase();
}

export function shortDate(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  return d.toLocaleDateString('en-AU', { day: 'numeric', month: 'short', timeZone: 'Australia/Melbourne' });
}
