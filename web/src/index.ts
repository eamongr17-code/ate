// web/src/index.ts — Ate's web pages for shared links (Cloudflare Worker on the Ate domain).
//
//   GET /entry/<uuid>   one post, as the signed-out Feed shows it (get_entry_card with the publishable
//                       key: every entry is public, 0033). Open Graph tags give Messages/WhatsApp a
//                       preview: the first photo, "@handle at Place". Deleted/blocked → "This post was deleted."
//   GET /list/<uuid>    lists are private (0060), so the page shows NOTHING of the list: just the way into
//                       the app. A member opens it in Ate.
//   GET /.well-known/apple-app-site-association   universal links: /entry/* and /list/* open the app
//                       when it is installed (Associated Domains entitlement, applinks:<domain>).
//   GET /logo.svg       the wordmark.
//   anything else       → the App link (TestFlight during the beta).
//
// Cost/volume: responses are cached at Cloudflare's edge for 5 minutes per URL, so a post shared to a
// group chat costs one Supabase read, not one per viewer. Workers' free plan is 100k requests a day.
// No cookies, no scripts or fonts from elsewhere (fonts are served from here), no tracking.

import logo from './logo.svg';
import dmsans from './fonts/dmsans.woff2';
import newsreader from './fonts/newsreader.woff2';
import youngserif from './fonts/youngserif.woff2';

// The three fonts, served from here (latin subsets, OFL): no viewer's IP goes to a font host.
const FONTS: Record<string, ArrayBuffer> = { dmsans, newsreader, youngserif };
import { ImageResponse } from 'workers-og';
import dmsans500 from './fonts/dmsans-500.ttf';
import dmsans700 from './fonts/dmsans-700.ttf';
import youngserifTTF from './fonts/youngserif.ttf';
import { aasa, entryPage, fetchCard, json, listPage, previewPhoto, type Env } from './render.ts';
import { ogHTML, ogParts } from './og.ts';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });
    }
    const path = url.pathname.replace(/\/+$/, '') || '/';

    if (path === '/.well-known/apple-app-site-association' || path === '/apple-app-site-association') {
      return json(aasa(env.APP_ID));
    }
    if (path === '/logo.svg') {
      return new Response(logo, {
        headers: { 'Content-Type': 'image/svg+xml', 'Cache-Control': 'public, max-age=86400' },
      });
    }

    const font = /^\/fonts\/(dmsans|newsreader|youngserif)\.woff2$/.exec(path);
    if (font) {
      return new Response(FONTS[font[1]], {
        headers: { 'Content-Type': 'font/woff2', 'Cache-Control': 'public, max-age=31536000, immutable' },
      });
    }

    const og = /^\/entry\/([0-9a-f-]{36})\/og\.png$/i.exec(path);
    if (og && UUID.test(og[1])) {
      const id = og[1].toLowerCase();
      const cache = caches.default;
      const key = new Request(`${url.origin}/entry/${id}/og.png`);
      const hit = await cache.match(key);
      if (hit) return hit;
      const image = await ogImage(id, env);
      if (image.status === 200) ctx.waitUntil(cache.put(key, image.clone()));
      return image;
    }

    const [, kind, id] = path.split('/');
    if ((kind === 'entry' || kind === 'list') && id && UUID.test(id)) {
      const cache = caches.default;
      const key = new Request(`${url.origin}/${kind}/${id.toLowerCase()}`);
      const hit = await cache.match(key);
      if (hit) return hit;
      const page = kind === 'entry'
        ? await entryPage(id.toLowerCase(), url.origin, env)
        : listPage(id.toLowerCase(), url.origin, env);
      if (page.status === 200) ctx.waitUntil(cache.put(key, page.clone()));
      return page;
    }

    return Response.redirect(env.APP_LINK, 302);
  },
};


const LOGO = `data:image/svg+xml;base64,${btoa(logo)}`;

/** The post's link preview image. Cached an hour at the edge, so one render per post per hour. */
async function ogImage(id: string, env: Env): Promise<Response> {
  let card;
  try {
    card = await fetchCard(id, env);
  } catch {
    return new Response('Unavailable', { status: 503 });
  }
  if (!card) return new Response('Not found', { status: 404 });
  const photo = await previewPhoto(card);
  const image = new ImageResponse(ogHTML(ogParts(card), photo, LOGO), {
    width: 1200,
    height: 630,
    fonts: [
      { name: 'DM Sans', data: dmsans500, weight: 500, style: 'normal' },
      { name: 'DM Sans', data: dmsans700, weight: 700, style: 'normal' },
      { name: 'Young Serif', data: youngserifTTF, weight: 400, style: 'normal' },
    ],
  });
  const headers = new Headers(image.headers);
  headers.set('Cache-Control', 'public, max-age=3600');
  return new Response(image.body, { status: 200, headers });
}
