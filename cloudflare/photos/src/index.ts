// cloudflare/photos/src/index.ts — the Ate photos Worker, on photos.<domain> (photos-staging.<domain>).
//
//   GET|HEAD /<bucket>/<uid>/<file>      public read from R2; phones may keep it a year (paths are write-once)
//   PUT      /v1/object/<bucket>/<path>  signed-in upload into your own folder only. Body = the image
//                                        (JPEG/PNG, checked by its bytes; ≤ 10 MB photos, ≤ 5 MB avatars)
//                                        → 200 {"url": "https://photos.<domain>/<bucket>/<path>"}
//   POST     /v1/delete                  signed in: {"keys": ["review-photos/<you>/…", …]} (≤ 100, yours only)
//   POST     /v1/purge                   service key: {"user_id": uid} empties that account's folders
//                                        (delete-account, after the account's rows are gone)
//   POST     /v1/import                  service key: {"keys": [≤ 10]} copies each from Supabase Storage
//                                        (public URL) into R2 unless already there; the one-off move
//   GET      /v1/health                  {"ok": true}
//
// Vars (wrangler.toml, set by .github/scripts/photos_setup.sh): SUPABASE_URL, SUPABASE_ANON_KEY,
// PUBLIC_BASE. Binding: PHOTOS (R2). No secrets: callers prove themselves to Supabase Auth.

import {
  BUCKETS, CACHE_CONTROL, bearer, isServiceKey, ownKeys, ownerOf, parseKey, publicUrl, purgeUser, sniff,
  supabaseUrl, userId,
} from './photos.ts';

type Env = {
  PHOTOS: R2Bucket;
  SUPABASE_URL: string;
  SUPABASE_ANON_KEY: string;
  PUBLIC_BASE: string;
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

async function read(req: Request, env: Env, pathname: string): Promise<Response> {
  const k = parseKey(pathname);
  if (!k) return new Response('not found', { status: 404 });
  // Straight from R2 every time, never from a Worker-side edge cache: a deleted photo (or a deleted
  // account's) must stop being served at once, and the Cache API can only forget in one data centre.
  // Phones keep their own copy (Cache-Control), so a photo is fetched about once per phone.
  const object = req.method === 'HEAD' ? await env.PHOTOS.head(k.key) : await env.PHOTOS.get(k.key);
  if (!object) return new Response('not found', { status: 404, headers: { 'Cache-Control': 'no-store' } });
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set('ETag', object.httpEtag);
  headers.set('Content-Length', String(object.size));
  headers.set('Cache-Control', CACHE_CONTROL);
  headers.set('X-Content-Type-Options', 'nosniff');
  const body = 'body' in object ? (object as R2ObjectBody).body : null;
  return new Response(req.method === 'HEAD' ? null : body, { headers });
}

async function upload(req: Request, env: Env, rawKey: string): Promise<Response> {
  const k = parseKey(rawKey);
  if (!k) return json({ error: 'bad path' }, 400);
  const uid = await userId(bearer(req), env.SUPABASE_URL, env.SUPABASE_ANON_KEY);
  if (!uid) return json({ error: 'unauthorized' }, 401);
  if (ownerOf(k) !== uid) return json({ error: 'not your folder' }, 403);

  const limit = BUCKETS[k.bucket];
  const declared = Number(req.headers.get('Content-Length') ?? '0');
  if (declared > limit) return json({ error: 'too large' }, 413);
  const bytes = new Uint8Array(await req.arrayBuffer());
  if (bytes.length === 0) return json({ error: 'empty' }, 400);
  if (bytes.length > limit) return json({ error: 'too large' }, 413);
  const type = sniff(bytes);
  if (!type) return json({ error: 'not a JPEG or PNG' }, 415);

  await env.PHOTOS.put(k.key, bytes, {
    httpMetadata: { contentType: type, cacheControl: CACHE_CONTROL },
    customMetadata: { owner: uid },
  });
  return json({ url: publicUrl(env.PUBLIC_BASE, k.key) });
}

async function remove(req: Request, env: Env): Promise<Response> {
  const uid = await userId(bearer(req), env.SUPABASE_URL, env.SUPABASE_ANON_KEY);
  if (!uid) return json({ error: 'unauthorized' }, 401);
  const body = (await req.json().catch(() => null)) as { keys?: unknown } | null;
  const keys = ownKeys(body?.keys, uid);
  if (!keys) return json({ error: 'bad keys' }, 400);
  await env.PHOTOS.delete(keys.map((k) => k.key));
  return json({ ok: true, removed: keys.length });
}

async function admin(req: Request, env: Env, what: 'purge' | 'import'): Promise<Response> {
  if (!(await isServiceKey(bearer(req), env.SUPABASE_URL))) return json({ error: 'unauthorized' }, 401);
  const body = (await req.json().catch(() => null)) as { user_id?: unknown; keys?: unknown } | null;

  if (what === 'purge') {
    const uid = typeof body?.user_id === 'string' ? body.user_id.toLowerCase() : '';
    try {
      return json({ ok: true, removed: await purgeUser(env.PHOTOS, uid) });
    } catch (e) {
      return json({ error: e instanceof Error ? e.message : String(e) }, 400);
    }
  }

  // import: copy each key from Supabase Storage's public URL, unless R2 already holds it
  if (!Array.isArray(body?.keys) || body.keys.length > 10) return json({ error: 'bad keys' }, 400);
  const results: { key: string; status: 'copied' | 'present' | 'missing' | 'bad'; size?: number }[] = [];
  for (const raw of body.keys) {
    const k = typeof raw === 'string' ? parseKey(raw) : null;
    if (!k) { results.push({ key: String(raw), status: 'bad' }); continue; }
    const head = await env.PHOTOS.head(k.key);
    if (head) { results.push({ key: k.key, status: 'present', size: head.size }); continue; }
    const res = await fetch(supabaseUrl(env.SUPABASE_URL, k.key), { redirect: 'manual' });
    if (!res.ok) { results.push({ key: k.key, status: 'missing' }); continue; }
    const bytes = new Uint8Array(await res.arrayBuffer());
    const type = sniff(bytes);
    if (!type || bytes.length > BUCKETS[k.bucket]) { results.push({ key: k.key, status: 'bad' }); continue; }
    await env.PHOTOS.put(k.key, bytes, {
      httpMetadata: { contentType: type, cacheControl: CACHE_CONTROL },
      customMetadata: { owner: ownerOf(k), from: 'supabase' },
    });
    results.push({ key: k.key, status: 'copied', size: bytes.length });
  }
  return json({ ok: true, results });
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const p = url.pathname;
    try {
      if (p === '/v1/health') return json({ ok: true });
      if (p.startsWith('/v1/object/')) {
        return req.method === 'PUT' ? upload(req, env, p.slice('/v1/object/'.length)) : json({ error: 'method' }, 405);
      }
      if (p === '/v1/delete') return req.method === 'POST' ? remove(req, env) : json({ error: 'method' }, 405);
      if (p === '/v1/purge') return req.method === 'POST' ? admin(req, env, 'purge') : json({ error: 'method' }, 405);
      if (p === '/v1/import') return req.method === 'POST' ? admin(req, env, 'import') : json({ error: 'method' }, 405);
      if (req.method === 'GET' || req.method === 'HEAD') return read(req, env, p);
      return json({ error: 'method' }, 405);
    } catch (e) {
      console.error('photos:', e instanceof Error ? e.message : String(e));
      return json({ error: 'server error' }, 500);
    }
  },
};
