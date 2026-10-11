// supabase/functions/read-share/url.ts
//
// What was shared, and its canonical form. PURE: no network, no runtime APIs, so the suite runs
// under Node as well as Deno (see ../sort-entry/harness.ts).
//
//   tiktok    — tiktok.com and every subdomain. Short links (vm./vt.tiktok.com/<code>,
//               tiktok.com/t/<code>) are flagged `short` so index.ts resolves them first.
//   instagram — instagram.com (+ www./m.) and instagr.am.
//   link      — any other https URL.
//
// The canonical URL is what own_saves.source_url stores (https only, ≤ 2048, see 0061): https, a
// lower-case host, no fragment, no tracking parameters. A TikTok video or Instagram post collapses
// to its one true address so the same post shared twice is the same string.

export type ShareSource = 'tiktok' | 'instagram' | 'link';

export type ClassifiedUrl = {
  source: ShareSource;
  /** Canonical https URL. */
  url: string;
  /** TikTok short link: follow its redirects before oEmbed. */
  short: boolean;
  /** An account named BY THE URL ITSELF (instagram.com/<user>/reel/…, tiktok.com/@user/…), else null. */
  author: string | null;
};

/** own_saves.source_url's own cap (0061). */
export const MAX_URL_LENGTH = 2048;

/** Query parameters that only ever say who shared a link, never what it is. */
const TRACKING_PARAMS = new Set([
  'fbclid', 'gclid', 'dclid', 'msclkid', 'igsh', 'igshid', 'si', 'mc_cid', 'mc_eid',
  '_r', '_t', 'is_from_webapp', 'sender_device', 'sender_web_id', 'share_app_id', 'share_link_id',
  'share_item_id', 'source', 'tt_from', 'u_code', 'user_id', 'timestamp', 'utm_id',
]);

const TIKTOK_VIDEO_RE = /^\/@([A-Za-z0-9._]{1,64})\/(video|photo)\/(\d{5,25})\/?$/;
const TIKTOK_SHORT_PATH_RE = /^\/t\/[A-Za-z0-9_-]{3,40}\/?$/;
const INSTAGRAM_POST_RE = /^\/(?:([A-Za-z0-9._]{1,30})\/)?(p|reel|reels|tv)\/([A-Za-z0-9_-]{3,64})\/?$/;

export function isTikTokHost(host: string): boolean {
  const h = host.toLowerCase();
  return h === 'tiktok.com' || h.endsWith('.tiktok.com');
}

export function isInstagramHost(host: string): boolean {
  const h = host.toLowerCase();
  return h === 'instagram.com' || h === 'www.instagram.com' || h === 'm.instagram.com' || h === 'instagr.am' ||
    h === 'www.instagr.am';
}

/** True for a TikTok short link that must be resolved by following its redirects. */
export function isTikTokShortLink(u: URL): boolean {
  const h = u.hostname.toLowerCase();
  if (h === 'vm.tiktok.com' || h === 'vt.tiktok.com') return u.pathname.length > 1;
  return (h === 'tiktok.com' || h === 'www.tiktok.com') && TIKTOK_SHORT_PATH_RE.test(u.pathname);
}

/** Parse an https URL, or null. Whitespace and a trailing sentence-ending dot are forgiven. */
export function parseHttpsUrl(raw: unknown): URL | null {
  if (typeof raw !== 'string') return null;
  const s = raw.trim();
  if (!s || s.length > MAX_URL_LENGTH) return null;
  let u: URL;
  try {
    u = new URL(s);
  } catch {
    return null;
  }
  if (u.protocol !== 'https:') return null;
  if (u.username || u.password) return null;
  if (!u.hostname || !u.hostname.includes('.')) return null;
  if (u.port && u.port !== '443') return null;
  return u;
}

function stripTracking(u: URL): void {
  for (const key of [...u.searchParams.keys()]) {
    if (key.toLowerCase().startsWith('utm_') || TRACKING_PARAMS.has(key.toLowerCase())) u.searchParams.delete(key);
  }
}

/**
 * Classify and canonicalise. null = not a usable https URL (the function answers 422).
 */
export function classifyUrl(raw: unknown): ClassifiedUrl | null {
  const u = parseHttpsUrl(raw);
  if (!u) return null;
  u.hash = '';
  u.hostname = u.hostname.toLowerCase();
  u.port = '';

  if (isTikTokHost(u.hostname)) {
    const video = TIKTOK_VIDEO_RE.exec(u.pathname);
    if (video) {
      return {
        source: 'tiktok',
        url: `https://www.tiktok.com/@${video[1]}/${video[2]}/${video[3]}`,
        short: false,
        author: null, // the oEmbed author_name is the display name; the handle alone is not used
      };
    }
    const short = isTikTokShortLink(u);
    if (short) u.search = '';
    else stripTracking(u);
    return { source: 'tiktok', url: u.toString(), short, author: null };
  }

  if (isInstagramHost(u.hostname)) {
    const post = INSTAGRAM_POST_RE.exec(u.pathname);
    if (post) {
      const kind = post[2] === 'reels' ? 'reel' : post[2];
      return {
        source: 'instagram',
        url: `https://www.instagram.com/${kind}/${post[3]}/`,
        short: false,
        author: post[1] && !['p', 'reel', 'reels', 'tv', 'explore', 'stories'].includes(post[1]) ? post[1] : null,
      };
    }
    stripTracking(u);
    return { source: 'instagram', url: u.toString(), short: false, author: null };
  }

  stripTracking(u);
  return { source: 'link', url: u.toString(), short: false, author: null };
}

/**
 * A resolved short link's destination, canonicalised — only when it lands on a TikTok VIDEO or
 * PHOTO page. Anything else (a login wall, a region page) → null, and the caller keeps what it had.
 */
export function canonicalTikTokVideo(raw: string): string | null {
  const c = classifyUrl(raw);
  if (!c || c.source !== 'tiktok' || c.short) return null;
  return /^https:\/\/www\.tiktok\.com\/@[^/]+\/(video|photo)\/\d+$/.test(c.url) ? c.url : null;
}

const URL_IN_TEXT_RE = /\bhttps?:\/\/[^\s<>"']+/gi;

/**
 * The share sheet's text with every URL taken out and whitespace tidied — what is left is the
 * caption (or nothing). Instagram typically passes only the link; TikTok sometimes passes
 * "<caption> <link>".
 */
export function textWithoutUrls(text: unknown, maxLength = 2200): string | null {
  if (typeof text !== 'string') return null;
  const s = text.replace(URL_IN_TEXT_RE, ' ').replace(/[ \t]+/g, ' ').replace(/\s*\n\s*/g, '\n').trim();
  return s ? s.slice(0, maxLength) : null;
}
