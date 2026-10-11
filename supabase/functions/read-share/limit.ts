// supabase/functions/read-share/limit.ts
//
// The per-user spend guard: READ_SHARE_LIMIT reads per READ_SHARE_WINDOW_S, fixed window — the
// same shape as 0013/0039's counters, held in the isolate rather than a table.
//
// WHY IN MEMORY. The two existing counters cannot be borrowed: places_rate_hit prunes every window
// older than ITS caller's (a 10-minute window would be wiped by every places-search call), and
// sort_preview_rate is the sorter's model budget (sharing it would 429 the composer's previews).
// A durable counter needs its own table (a 0013-shaped migration), which this function does not
// require to ship: the cross-isolate ceiling is index.ts ALSO recording each read against
// places_rate_hit at places-search's own 60 s / 90 policy (read-share spends on the same Google
// key), and every model call is capped at a few hundred tokens. An isolate restart forgets this
// window; a determined abuser spread across isolates still meets the places ceiling.
//
// PURE (clock injected) so the suite runs under Node.

export const READ_SHARE_LIMIT = 30;
export const READ_SHARE_WINDOW_S = 10 * 60;
/** Bound the map so a flood of distinct users cannot grow it without limit. */
const MAX_TRACKED = 10_000;

export class WindowLimiter {
  private readonly hits = new Map<string, { window: number; count: number }>();
  private readonly limit: number;
  private readonly windowMs: number;

  constructor(limit = READ_SHARE_LIMIT, windowSeconds = READ_SHARE_WINDOW_S) {
    this.limit = limit;
    this.windowMs = windowSeconds * 1000;
  }

  /** Record one hit; true when it is within the limit. */
  hit(key: string, nowMs: number = Date.now()): boolean {
    const window = Math.floor(nowMs / this.windowMs);
    const cur = this.hits.get(key);
    if (cur && cur.window === window) {
      cur.count += 1;
      return cur.count <= this.limit;
    }
    if (this.hits.size >= MAX_TRACKED) {
      for (const [k, v] of this.hits) if (v.window !== window) this.hits.delete(k);
      if (this.hits.size >= MAX_TRACKED) this.hits.clear();
    }
    this.hits.set(key, { window, count: 1 });
    return 1 <= this.limit;
  }
}
