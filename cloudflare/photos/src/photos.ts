// cloudflare/photos/src/photos.ts
//
// Ate's photo store on Cloudflare R2 (Nov 2026): the rules, with no Cloudflare in them, so Node runs the
// suite. index.ts wires them to the R2 binding and the Supabase project.
//
// One R2 bucket per environment. Its keys keep Supabase Storage's layout, bucket name first:
//   review-photos/<uid>/<entry>-<n>.jpg   (+ <…>_t.jpg thumbnails, list-covers/<list>.jpg)
//   avatars/<uid>/avatar.jpg
// so moving a photo is one prefix swap on its URL:
//   https://<ref>.supabase.co/storage/v1/object/public/review-photos/u/e-0.jpg
//   https://photos.<domain>/review-photos/u/e-0.jpg

/** The two public buckets, and the biggest file each takes (0092's limits). */
export const BUCKETS: Record<string, number> = {
  'review-photos': 10 * 1024 * 1024,
  avatars: 5 * 1024 * 1024,
};

export const IMAGE_TYPES = ['image/jpeg', 'image/png'] as const;
export type ImageType = (typeof IMAGE_TYPES)[number];

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
/** 0094's storage_url_ok character set, one to three segments under the owner's folder. */
const SAFE_PATH = /^[A-Za-z0-9._-]+(\/[A-Za-z0-9._-]+){1,3}$/;

export type Key = { bucket: string; path: string; key: string };

/**
 * `review-photos/<uid>/x.jpg` → its parts, or null when it is not a key we would ever store: an unknown
 * bucket, a first folder that is not a lower-case uid, `..`, or anything outside the safe characters.
 */
export function parseKey(raw: string): Key | null {
  let key: string;
  try {
    key = decodeURIComponent(raw.replace(/^\/+/, ''));
  } catch {
    return null;
  }
  const slash = key.indexOf('/');
  if (slash < 0) return null;
  const bucket = key.slice(0, slash);
  const path = key.slice(slash + 1);
  if (!(bucket in BUCKETS)) return null;
  if (!SAFE_PATH.test(path) || path.includes('..')) return null;
  if (!UUID.test(path.split('/')[0])) return null;
  return { bucket, path, key: `${bucket}/${path}` };
}

/** The owner of a key: its first folder. */
export const ownerOf = (k: Key) => k.path.split('/')[0];

/** What the bytes say they are: JPEG (FF D8 FF) or PNG (89 50 4E 47), else null. */
export function sniff(bytes: Uint8Array): ImageType | null {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg';
  if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
    return 'image/png';
  }
  return null;
}

/**
 * Every object path is write-once in practice (an entry's photo is `<entry>-<n>.jpg`; an edit's added
 * photo gets a fresh name; avatars and covers carry a `?v=` buster in their URL), so a phone may keep
 * its copy for a year.
 */
export const CACHE_CONTROL = 'public, max-age=31536000, immutable';

/** `https://photos.x/` + key: the URL the database stores. */
export function publicUrl(base: string, key: string): string {
  return `${base.replace(/\/+$/, '')}/${key}`;
}

/** The Supabase public URL of a key: where a photo lived before R2. */
export function supabaseUrl(supabase: string, key: string): string {
  return `${supabase.replace(/\/+$/, '')}/storage/v1/object/public/${key}`;
}

export const bearer = (req: Request) =>
  (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim();

/**
 * Who the caller is, asked of Supabase Auth itself (`/auth/v1/user`): the same check every edge function
 * makes, so a signed-out, expired, or deleted account is refused whatever key type the project signs
 * with. `null` = not signed in.
 */
export async function userId(
  token: string,
  supabase: string,
  anonKey: string,
  fetchImpl: typeof fetch = fetch,
): Promise<string | null> {
  if (!token) return null;
  try {
    const res = await fetchImpl(`${supabase.replace(/\/+$/, '')}/auth/v1/user`, {
      headers: { apikey: anonKey, Authorization: `Bearer ${token}` },
    });
    if (!res.ok) return null;
    const body = (await res.json()) as { id?: unknown };
    return typeof body.id === 'string' && UUID.test(body.id.toLowerCase()) ? body.id.toLowerCase() : null;
  } catch {
    return null;
  }
}

/**
 * Whether `key` is the project's service-role (or `sb_secret_`) key: only that key may list the admin
 * users endpoint. The account purge and the copy-in are server-to-server; no extra shared secret exists
 * to leak or rotate.
 */
export async function isServiceKey(key: string, supabase: string, fetchImpl: typeof fetch = fetch): Promise<boolean> {
  if (!key) return false;
  try {
    const res = await fetchImpl(`${supabase.replace(/\/+$/, '')}/auth/v1/admin/users?page=1&per_page=1`, {
      headers: { apikey: key, Authorization: `Bearer ${key}` },
    });
    return res.ok;
  } catch {
    return false;
  }
}

/** The smallest slice of R2's API the purge needs (an R2Bucket satisfies it). */
export type Store = {
  list(opts: { prefix: string; cursor?: string; limit?: number }): Promise<{
    objects: { key: string }[];
    truncated: boolean;
    cursor?: string;
  }>;
  delete(keys: string | string[]): Promise<void>;
};

const PURGE_PAGES = 100;

/** Deletes everything under `<bucket>/<uid>/` in every bucket. Bounded; returns how many went. */
export async function purgeUser(store: Store, uid: string): Promise<number> {
  if (!UUID.test(uid)) throw new Error('not a user id');
  let removed = 0;
  for (const bucket of Object.keys(BUCKETS)) {
    const prefix = `${bucket}/${uid}/`;
    for (let page = 0; page < PURGE_PAGES; page++) {
      // always the first page: what was listed is deleted before the next look
      const listed = await store.list({ prefix, limit: 1000 });
      const keys = listed.objects.map((o) => o.key).filter((k) => k.startsWith(prefix));
      if (!keys.length) break;
      await store.delete(keys);
      removed += keys.length;
      if (!listed.truncated) break;
    }
  }
  return removed;
}

/** The keys a delete request may remove: parsed, the caller's own, at most 100, each once. */
export function ownKeys(raw: unknown, uid: string): Key[] | null {
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > 100) return null;
  const out = new Map<string, Key>();
  for (const r of raw) {
    if (typeof r !== 'string') return null;
    const k = parseKey(r);
    if (!k || ownerOf(k) !== uid) return null;
    out.set(k.key, k);
  }
  return [...out.values()];
}
