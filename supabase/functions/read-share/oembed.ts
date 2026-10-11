// supabase/functions/read-share/oembed.ts
//
// TikTok's public oEmbed (no key, no cost): https://www.tiktok.com/oembed?url=<post url>
//   → { title (the caption), author_name, author_unique_id, thumbnail_url, … }
// PURE: builds the request URL and parses the reply. The fetch itself is ./fetch.ts's.
//
// Instagram has no keyless equivalent (Meta's oEmbed Read needs an approved app — beta-approach §5),
// so an Instagram share carries only what the share sheet passed as text.

export const TIKTOK_OEMBED = 'https://www.tiktok.com/oembed';

export type PostMeta = { author: string | null; caption: string | null; thumbnail_url: string | null };

export const EMPTY_META: PostMeta = { author: null, caption: null, thumbnail_url: null };

/** own_saves caps (0061): author ≤ 100, caption ≤ 2200. */
export const MAX_AUTHOR = 100;
export const MAX_CAPTION = 2200;

export function tiktokOEmbedUrl(postUrl: string): string {
  return `${TIKTOK_OEMBED}?url=${encodeURIComponent(postUrl)}`;
}

const str = (v: unknown, max: number): string | null => {
  if (typeof v !== 'string') return null;
  const s = v.replace(/\s+/g, ' ').trim();
  return s ? s.slice(0, max) : null;
};

/** A thumbnail is kept only as an https URL of sane length. */
export function httpsOrNull(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  try {
    const u = new URL(v.trim());
    return u.protocol === 'https:' && u.toString().length <= 2048 ? u.toString() : null;
  } catch {
    return null;
  }
}

/** Parse a TikTok oEmbed body (string or object). Anything unusable → EMPTY_META, never a throw. */
export function parseTikTokOEmbed(body: unknown): PostMeta {
  let j: unknown = body;
  if (typeof body === 'string') {
    try {
      j = JSON.parse(body);
    } catch {
      return EMPTY_META;
    }
  }
  if (!j || typeof j !== 'object' || Array.isArray(j)) return EMPTY_META;
  const o = j as Record<string, unknown>;
  // A failed lookup answers 200/400 with { code, message } and no title.
  const caption = str(o.title, MAX_CAPTION);
  const handle = str(o.author_unique_id, MAX_AUTHOR - 1);
  return {
    author: str(o.author_name, MAX_AUTHOR) ?? (handle ? `@${handle}` : null),
    caption,
    thumbnail_url: httpsOrNull(o.thumbnail_url),
  };
}
