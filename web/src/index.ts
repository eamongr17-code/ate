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
// No cookies, no scripts from elsewhere, no tracking.

import logo from './logo.svg';
import { aasa, entryPage, json, listPage, type Env } from './render.ts';

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

