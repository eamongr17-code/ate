// supabase/tests/db/fixtures.mjs — the shared world the read/behaviour suites build on.
//
// One small, fully known dataset instead of the staging seed: four people, five places (one with an
// accented name, one far out of town, one with no address), and a `visit` helper that writes an entry
// exactly the way the app + sorter do (INSERT as the author, then apply_entry_sort as service_role).
// Offsets are Unicode SCALARS, like every offset on the wire, so a body with `ragù` in it is honest.
//
//   import { world, U, P, id } from './fixtures.mjs';
//   const w = await world();           // boots PGlite, applies every migration, inserts people + places
//   await w.visit(1, U.alice, P.tipo, receipt(['Gnocchi', 4.5], ['Tiramisu']), '2026-09-01T09:00:00Z');

import { actors, boot } from './harness.mjs';

export const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
export const point = (lng, lat) => `extensions.ST_SetSRID(extensions.ST_MakePoint(${lng}, ${lat}), 4326)::geography`;
export const photoUrl = (path) =>
  `https://cvoitgoaosofkougmarn.supabase.co/storage/v1/object/public/review-photos/${path}`;
/** Length / offset in Unicode scalars — the unit every offset on the wire is in. */
export const scalars = (s) => [...s].length;

export const U = {
  alice: '00000000-0000-4000-8000-00000000000a',
  bob: '00000000-0000-4000-8000-00000000000b',
  cleo: '00000000-0000-4000-8000-00000000000c',
  dan: '00000000-0000-4000-8000-00000000000d',
};

export const P = {
  tipo: '00000000-0000-4000-8000-0000000000f1', //  Italian, Melbourne CBD, full Google-style address
  marion: '00000000-0000-4000-8000-0000000000f2', // Wine bar, Fitzroy
  osteria: '00000000-0000-4000-8000-0000000000f3', // Italian, Carlton — the accented menu (ragù)
  far: '00000000-0000-4000-8000-0000000000f4', //    Thai, Geelong — 60 km out
  hand: '00000000-0000-4000-8000-0000000000f5', //   typed by hand: no address, no point
};

const PLACES_SQL = `
  insert into public.restaurants (id, name, address, city, cuisine, source, location) values
    ('${P.tipo}',    'Tipo 00',       '361 Little Bourke St, Melbourne VIC 3000, Australia', 'Melbourne', 'Italian',  'manual', ${point(144.9631, -37.8136)}),
    ('${P.marion}',  'Marion',        '53 Gertrude St, Fitzroy VIC 3065, Australia',         'Fitzroy',   'Wine bar', 'manual', ${point(144.9820, -37.8060)}),
    ('${P.osteria}', 'Osteria Ilaria','367 Lygon St, Carlton VIC 3053, Australia',            'Carlton',   'Italian',  'manual', ${point(144.9671, -37.8000)}),
    ('${P.far}',     'Tipo Far',      '1 Moorabool St, Geelong VIC 3220, Australia',          'Geelong',   'Thai',     'manual', ${point(144.3600, -38.1490)}),
    ('${P.hand}',    'Corner Cafe',   null,                                                   'Fitzroy',   null,       'manual', null);
`;

/**
 * A receipt: `[dish, score?, { tags?, note?, lead? }]` parts → `{ body, items }` with the mention and
 * evidence offsets the sorter would have recorded. A part with no score is an unscored line ("… was
 * lovely"), the normal case.
 */
export function receipt(...parts) {
  let body = '';
  const items = [];
  for (const [dish, score, extra = {}] of parts) {
    const sep = body === '' ? '' : '. ';
    const mentionAt = scalars(body) + scalars(sep);
    const scoreText = score == null ? null : Number.isInteger(score) ? String(score) : score.toFixed(1);
    const evidence = score == null ? null : `${dish} ${scoreText}`;
    const sentence = score == null ? `${dish} was lovely` : evidence;
    body += sep + sentence;
    const item = { dish_name: dish, mention_text: dish, mention_offset: mentionAt, tags: extra.tags ?? [] };
    if (score != null) Object.assign(item, { score, score_evidence: evidence, evidence_offset: mentionAt });
    if (extra.note) item.note = extra.note;
    items.push(item);
  }
  return { body, items };
}

/** Boots a database with the migration chain, the four people and the five places. */
export async function world({ people = Object.values(U), places = true } = {}) {
  const db = await boot();
  const { as, asService, rows, error } = actors(db);
  const names = Object.fromEntries(Object.entries(U).map(([k, v]) => [v, k]));
  for (const uid of people) {
    await db.query(`insert into auth.users (id, email) values ($1, $2)`, [uid, `${names[uid] ?? uid.slice(-4)}@ate.test`]);
  }
  if (places) await db.exec(PLACES_SQL);

  const sortAs = (entryId, place, items, extra = {}) =>
    asService(() => db.query(
      `select public.apply_entry_sort(p_entry_id => $1, p_restaurant_id => $2, p_items => $3::jsonb, p_mode => 'stub',
         p_place_query => $4, p_place_offset => $5)`,
      [entryId, place, JSON.stringify(items), extra.placeQuery ?? null, extra.placeOffset ?? null],
    ));

  /**
   * An entry by `author` at `place` written at `when`, sorted to `r.items`. `photos` are storage paths
   * (entry_photos rows, positions 0…). Returns the entry id.
   */
  async function visit(n, author, place, r, when = new Date().toISOString(), { photos = [], placeQuery, placeOffset } = {}) {
    await as(author, () => db.query(
      `insert into public.entries (id, author_id, body, restaurant_id, created_at) values ($1, $2, $3, $4, $5)`,
      [id(n), author, r.body, place, when],
    ));
    await sortAs(id(n), place, r.items, { placeQuery, placeOffset });
    for (const [i, path] of photos.entries()) {
      await as(author, () => db.query(
        `insert into public.entry_photos (entry_id, position, photo_url) values ($1, $2, $3)`,
        [id(n), i, photoUrl(path)],
      ));
    }
    return id(n);
  }

  /** A pre-0040 placeless entry — the only way one exists now. Superuser, local PGlite only. */
  async function legacyPlaceless(entryId, author, body, when = new Date().toISOString()) {
    await db.exec(`alter table public.entries disable trigger entries_place_required;`);
    try {
      await db.query(`insert into public.entries (id, author_id, body, created_at) values ($1, $2, $3, $4)`,
        [entryId, author, body, when]);
    } finally {
      await db.exec(`alter table public.entries enable trigger entries_place_required;`);
    }
  }

  /** Read a keyset walk page by page: `page(last)` returns rows after `last` (null = first page). */
  async function walk(page, { max = 200 } = {}) {
    const out = [];
    let last = null;
    for (let i = 0; i < max; i++) {
      const got = await page(last);
      out.push(...got);
      if (got.length === 0) break;
      last = got.at(-1);
    }
    return out;
  }

  return { db, as, asService, rows, error, sortAs, visit, legacyPlaceless, walk };
}
