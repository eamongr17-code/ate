// supabase/functions/read-share/fetch.ts
//
// Every byte read-share pulls off the internet comes through here: https only, a hard timeout, a
// response-size cap, manual redirects (each hop re-checked), and — for the generic link path, where
// the URL is anybody's — an SSRF guard that refuses localhost, private / link-local / CGNAT /
// metadata addresses and internal-looking names, both as literals and (when a resolver is supplied)
// after DNS resolution.
//
// Runtime-free apart from the global fetch (injectable) so the suite runs under Node too. The
// resolver is injected by index.ts (Deno.resolveDns); without one the literal checks still apply.
// Residual risk, accepted: DNS rebinding between our lookup and fetch's own. The response we read is
// capped and only meta tags are kept from it, so the most a rebind could do is echo a title back.

export type Resolver = (host: string) => Promise<string[]>;

export const USER_AGENT = 'Mozilla/5.0 (compatible; AteShare/1.0)';

// ---------------------------------------------------------------------------
// Address classification.
// ---------------------------------------------------------------------------

function ipv4Parts(s: string): number[] | null {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(s);
  if (!m) return null;
  const parts = m.slice(1).map(Number);
  return parts.every((n) => n >= 0 && n <= 255) ? parts : null;
}

function isPrivateIPv4([a, b]: number[]): boolean {
  return (
    a === 0 || a === 10 || a === 127 ||
    (a === 100 && b >= 64 && b <= 127) || // CGNAT
    (a === 169 && b === 254) || // link-local, cloud metadata
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    (a === 192 && b === 0) || // 192.0.0/24 + 192.0.2/24 (protocol assignments, TEST-NET-1)
    (a === 198 && (b === 18 || b === 19)) || // benchmarking
    (a === 198 && b === 51) || (a === 203 && b === 0) || // TEST-NETs (coarse, harmless)
    a >= 224 // multicast + reserved + broadcast
  );
}

/** True when an IP literal (v4 or v6, brackets allowed) is not a public unicast address. */
export function isPrivateAddress(ip: string): boolean {
  let s = ip.trim().toLowerCase();
  if (s.startsWith('[') && s.endsWith(']')) s = s.slice(1, -1);
  const v4 = ipv4Parts(s);
  if (v4) return isPrivateIPv4(v4);
  if (!s.includes(':')) return false; // not an IP literal at all
  if (s === '::' || s === '::1') return true;
  // IPv4-mapped / -compatible (::ffff:10.0.0.1, ::ffff:a00:1) — judge the embedded v4.
  const mappedDotted = /^(?:0{0,4}:){0,5}(?:ffff:)?(\d{1,3}(?:\.\d{1,3}){3})$/.exec(s);
  if (mappedDotted) {
    const p = ipv4Parts(mappedDotted[1]);
    return p ? isPrivateIPv4(p) : true;
  }
  const mappedHex = /^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/.exec(s);
  if (mappedHex) {
    const hi = parseInt(mappedHex[1], 16);
    const lo = parseInt(mappedHex[2], 16);
    return isPrivateIPv4([hi >> 8, hi & 255, lo >> 8, lo & 255]);
  }
  const first = parseInt(s.split(':')[0] || '0', 16);
  if (Number.isNaN(first)) return true;
  return (
    (first & 0xfe00) === 0xfc00 || // fc00::/7 unique local
    (first & 0xffc0) === 0xfe80 || // fe80::/10 link-local
    (first & 0xff00) === 0xff00 || // multicast
    s.startsWith('64:ff9b:') || // NAT64 (could reach v4 internals)
    s.startsWith('2001:db8:') || // documentation
    first === 0 // anything else in ::/16 (deprecated compat, unspecified)
  );
}

const INTERNAL_SUFFIXES = ['.localhost', '.local', '.internal', '.lan', '.home.arpa', '.intranet', '.corp'];

/** True when a hostname must never be fetched: localhost, internal suffixes, single labels, private IPs. */
export function isBlockedHost(hostname: string): boolean {
  const h = hostname.trim().toLowerCase().replace(/\.$/, '');
  if (!h) return true;
  if (h === 'localhost' || INTERNAL_SUFFIXES.some((s) => h.endsWith(s))) return true;
  if (h.startsWith('[') || h.includes(':') || ipv4Parts(h)) return isPrivateAddress(h);
  if (/^[0-9.]+$/.test(h) || /^0x/i.test(h)) return true; // odd numeric forms (010.1, 0x7f.1)
  if (!h.includes('.')) return true;
  return false;
}

// ---------------------------------------------------------------------------
// Fetching.
// ---------------------------------------------------------------------------

export type SafeFetchOptions = {
  timeoutMs: number;
  maxBytes: number;
  maxHops?: number;
  /** Every hop's host must pass this (e.g. TikTok-only for short links). Default: any public host. */
  allowHost?: (host: string) => boolean;
  /** Resolve and refuse private addresses (generic links). */
  resolver?: Resolver;
  accept?: string;
  fetchImpl?: typeof fetch;
};

export type SafeFetchResult = { status: number; url: string; contentType: string; body: string | null };

/** The URL is fetchable: https, default port, a public host (and public addresses, if resolvable). */
export async function hostIsSafe(u: URL, opts: Pick<SafeFetchOptions, 'allowHost' | 'resolver'>): Promise<boolean> {
  if (u.protocol !== 'https:' || u.username || u.password) return false;
  if (u.port && u.port !== '443') return false;
  if (isBlockedHost(u.hostname)) return false;
  if (opts.allowHost && !opts.allowHost(u.hostname)) return false;
  if (opts.resolver) {
    try {
      const addrs = await opts.resolver(u.hostname.replace(/^\[|\]$/g, ''));
      if (!addrs.length || addrs.some(isPrivateAddress)) return false;
    } catch {
      return false; // cannot prove it public → do not fetch
    }
  }
  return true;
}

/** Read at most maxBytes of a body as UTF-8. `truncate` keeps the head; otherwise over-cap → null. */
export async function readCapped(res: Response, maxBytes: number, truncate: boolean): Promise<string | null> {
  const declared = Number(res.headers.get('content-length') ?? '');
  if (!truncate && Number.isFinite(declared) && declared > maxBytes) {
    await res.body?.cancel().catch(() => {});
    return null;
  }
  if (!res.body) return '';
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const room = maxBytes - total;
      if (value.byteLength > room) {
        if (!truncate) return null;
        chunks.push(value.subarray(0, room));
        total = maxBytes;
        break;
      }
      chunks.push(value);
      total += value.byteLength;
    }
  } finally {
    reader.cancel().catch(() => {});
  }
  const all = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    all.set(c, at);
    at += c.byteLength;
  }
  return new TextDecoder('utf-8', { fatal: false }).decode(all);
}

/**
 * GET with manual redirects; every hop is re-checked by hostIsSafe. Returns the final status + URL
 * and (unless `bodyless`) the capped body. null on timeout, a refused hop, or too many hops.
 */
export async function safeFetch(
  url: string,
  opts: SafeFetchOptions & { bodyless?: boolean; truncate?: boolean },
): Promise<SafeFetchResult | null> {
  const doFetch = opts.fetchImpl ?? fetch;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), opts.timeoutMs);
  let current = url;
  try {
    for (let hop = 0; hop <= (opts.maxHops ?? 3); hop++) {
      let u: URL;
      try {
        u = new URL(current);
      } catch {
        return null;
      }
      if (!(await hostIsSafe(u, opts))) return null;
      const res = await doFetch(u.toString(), {
        method: 'GET',
        redirect: 'manual',
        signal: controller.signal,
        headers: { 'user-agent': USER_AGENT, accept: opts.accept ?? '*/*' },
      });
      if (res.status >= 300 && res.status < 400) {
        const loc = res.headers.get('location');
        await res.body?.cancel().catch(() => {});
        if (!loc) return null;
        current = new URL(loc, u).toString();
        continue;
      }
      const contentType = (res.headers.get('content-type') ?? '').toLowerCase();
      if (opts.bodyless) {
        await res.body?.cancel().catch(() => {});
        return { status: res.status, url: u.toString(), contentType, body: null };
      }
      const body = await readCapped(res, opts.maxBytes, opts.truncate ?? false);
      return { status: res.status, url: u.toString(), contentType, body };
    }
    return null; // too many hops
  } catch {
    return null; // timeout, network, TLS
  } finally {
    clearTimeout(timer);
  }
}

// ---------------------------------------------------------------------------
// Open Graph (generic links).
// ---------------------------------------------------------------------------

export type OpenGraph = { title: string | null; description: string | null; image: string | null };

const NAMED_ENTITIES: Record<string, string> = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', ndash: '–', mdash: '—', hellip: '…',
  rsquo: '’', lsquo: '‘', rdquo: '”', ldquo: '“',
};

export function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (whole, ent: string) => {
    if (ent[0] === '#') {
      const code = ent[1] === 'x' || ent[1] === 'X' ? parseInt(ent.slice(2), 16) : parseInt(ent.slice(1), 10);
      return Number.isFinite(code) && code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : whole;
    }
    return NAMED_ENTITIES[ent.toLowerCase()] ?? whole;
  });
}

function attrs(tag: string): Record<string, string> {
  const out: Record<string, string> = {};
  const re = /([a-zA-Z_:.-]+)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(tag))) out[m[1].toLowerCase()] = m[3] ?? m[4] ?? m[5] ?? '';
  return out;
}

const clean = (s: string | undefined, max: number) => {
  if (!s) return null;
  const v = decodeEntities(s).replace(/\s+/g, ' ').trim();
  return v ? v.slice(0, max) : null;
};

/** og:title / og:description / og:image (falling back to <title> and meta description). */
export function parseOpenGraph(html: string): OpenGraph {
  const head = html.slice(0, 256 * 1024);
  const meta: Record<string, string> = {};
  for (const m of head.matchAll(/<meta\b[^>]*>/gi)) {
    const a = attrs(m[0]);
    const key = (a.property ?? a.name ?? '').toLowerCase();
    if (key && a.content !== undefined && !(key in meta)) meta[key] = a.content;
  }
  const titleTag = /<title[^>]*>([^<]{1,500})<\/title>/i.exec(head)?.[1];
  const image = clean(meta['og:image'] ?? meta['og:image:secure_url'] ?? meta['twitter:image'], 2048);
  return {
    title: clean(meta['og:title'] ?? meta['twitter:title'] ?? titleTag, 300),
    description: clean(meta['og:description'] ?? meta['twitter:description'] ?? meta['description'], 2200),
    image: image && /^https:\/\//i.test(image) ? image : null,
  };
}
