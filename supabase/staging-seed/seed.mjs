#!/usr/bin/env node
// supabase/staging-seed/seed.mjs — the round-6 STAGING dummy dataset. Never prod.
//
//   node supabase/staging-seed/seed.mjs                  generate only: writes the SQL batches to
//                                                        $SEED_OUT (default: a temp dir) and prints counts
//   node supabase/staging-seed/seed.mjs --apply          remove any previous batch, then load this one
//   node supabase/staging-seed/seed.mjs --remove --i-mean-it   take the whole batch back out (remove.sql)
//
// WHAT IT MAKES (deterministic — the same rows every run): 60 demo accounts (seed.<handle>@ate.test,
// password atedemo123), 300 restaurants across Melbourne/Sydney/Brisbane/Adelaide/Perth with real suburb
// coordinates, ~1,500 entries over the last 18 months (~5,000 receipt lines: realistic score spread,
// unscored lines, dietary tags, a few secret 6s), saves, and 60 entries + 40 saves in eamon@ate.test's
// name so his Journal has range to filter. Entries go in the way the app and sorter write them: an
// INSERT, then the sorter's SQL write path apply_entry_sort (no model call), then photo rows that
// reuse the earlier demo seed's files in storage (nothing is uploaded or downloaded).
//
// SAFETY: the project ref is hard-coded to staging and passed explicitly on every call; every SQL batch
// first runs staging_seed.assert_staging(), which refuses any database that is not staging. Every row
// made is recorded in the staging_seed registry (setup.sql), and remove.sql deletes exactly those —
// never a real row, and never a seeded restaurant a real row has since used.

import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as D from './data.mjs';

const STAGING_REF = 'cvoitgoaosofkougmarn';
const HERE = dirname(fileURLToPath(import.meta.url));
const WORKDIR = join(HERE, '..', '..');
const NOW = Date.parse(process.env.SEED_NOW ?? '2026-09-28T00:00:00Z');
const DAY = 86400000;
const SPAN_DAYS = 548; // 18 months

// ---------------------------------------------------------------------------------------------------
// Determinism
// ---------------------------------------------------------------------------------------------------
let state = 0x5eed2606;
const rand = () => {
  state = (state + 0x6d2b79f5) | 0;
  let t = Math.imul(state ^ (state >>> 15), 1 | state);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
const int = (lo, hi) => lo + Math.floor(rand() * (hi - lo + 1));
const pick = (xs) => xs[Math.floor(rand() * xs.length)];
const weighted = (xs, w) => {
  const total = xs.reduce((s, x) => s + w(x), 0);
  let r = rand() * total;
  for (const x of xs) if ((r -= w(x)) <= 0) return x;
  return xs[xs.length - 1];
};
const normal = () => Math.sqrt(-2 * Math.log(1 - rand())) * Math.cos(2 * Math.PI * rand());
const uuid = (key) => {
  const h = createHash('sha1').update(`ate-staging-seed-r6:${key}`).digest('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-${'89ab'[parseInt(h[16], 16) % 4]}${h.slice(17, 20)}-${h.slice(20, 32)}`;
};
const cp = (s) => [...s].length; // offsets are Unicode scalars (the DB's), not UTF-16

// ---------------------------------------------------------------------------------------------------
// Restaurants
// ---------------------------------------------------------------------------------------------------
const restaurants = [];
const cuisineNames = Object.keys(D.CUISINES);
for (const [city, c] of Object.entries(D.CITIES)) {
  const used = new Set();
  for (let i = 0; i < c.restaurants; i++) {
    const cuisine = weighted(cuisineNames, (k) => D.CUISINES[k].w);
    const cz = D.CUISINES[cuisine];
    let name;
    for (let tries = 0; tries < 50; tries++) {
      name = pick(cz.names).replace('X', pick(D.NAME_WORDS));
      if (!used.has(name)) break;
    }
    if (used.has(name)) name = `${name} ${i}`;
    used.add(name);
    const [suburb, lat, lng, postcode] = weighted(c.suburbs, (s) => s[4]);
    const street = `${int(1, 420)} ${pick(c.streets)}`;
    const menu = [...cz.menu].sort(() => rand() - 0.5).slice(0, Math.min(cz.menu.length, int(6, 11)))
      .map(([dish, tags], k) => ({ dish, tags, pop: 1 / (k + 1.5), q: 0 }));
    const quality = 3.75 + normal() * 0.4;
    for (const m of menu) m.q = quality + normal() * 0.45;
    restaurants.push({
      id: uuid(`restaurant:${city}:${i}`), metro: city, city: suburb, name, cuisine, rank: i,
      google_place_id: `seed-r6-${city}-${i}`,
      address: `${street}, ${suburb} ${c.state} ${postcode}, Australia`,
      lat: +(lat + (rand() - 0.5) * 0.012).toFixed(6), lng: +(lng + (rand() - 0.5) * 0.014).toFixed(6),
      created_at: new Date(NOW - (SPAN_DAYS + int(10, 200)) * DAY).toISOString(),
      menu,
    });
  }
}
const byCity = Object.fromEntries(Object.keys(D.CITIES).map((c) => [c, restaurants.filter((r) => r.metro === c)]));

// ---------------------------------------------------------------------------------------------------
// People
// ---------------------------------------------------------------------------------------------------
if (D.HANDLES.length !== 60) throw new Error(`need 60 handles, have ${D.HANDLES.length}`);
const cityNames = { melbourne: 'Melbourne', sydney: 'Sydney', brisbane: 'Brisbane', adelaide: 'Adelaide', perth: 'Perth' };
const users = D.HANDLES.map((handle, i) => {
  const home = D.HOME_HINTS[handle] ?? weighted(['melbourne', 'sydney', 'brisbane', 'adelaide', 'perth'],
    (c) => ({ melbourne: 58, sydney: 24, brisbane: 7, adelaide: 6, perth: 5 })[c]);
  const first = pick(D.FIRST);
  return {
    id: uuid(`user:${handle}`), handle, username: handle, home,
    email: `seed.${handle}@ate.test`,
    name: handle.length <= 3 ? first : `${first} ${pick(D.LAST)}`,
    bio: pick(D.BIOS),
    city: cityNames[home],
    avatar_url: rand() < 0.7 ? `https://i.pravatar.cc/300?img=${int(1, 70)}` : null,
    tastes: D.TASTE_HINTS[handle] ?? null,
    weight: 1 / Math.pow(i + 3, 0.9),
    created_at: new Date(NOW - (SPAN_DAYS + int(5, 120)) * DAY).toISOString(),
  };
});
// A stable shuffle so activity is not ordered by the handle list.
users.sort((a, b) => a.id.localeCompare(b.id));
users.forEach((u, i) => { u.weight = 1 / Math.pow(i + 3, 0.9); });

// ---------------------------------------------------------------------------------------------------
// Entries
// ---------------------------------------------------------------------------------------------------
const halfStep = (x) => Math.min(5, Math.max(0.5, Math.round(x * 2) / 2));
const scoreText = (s) => (s === Math.floor(s) ? String(s) : s.toFixed(1));
const fill = (t) => t.replace('{W}', pick(D.WHO)).replace('{V}', pick(D.VIBES)).replace('{O}', pick(D.OCCASIONS));
let sixes = 0;

function drawDate() {
  // Weighted toward recent: more people, more entries lately.
  const back = Math.floor(Math.pow(rand(), 1.6) * SPAN_DAYS) + 1;
  const d = new Date(NOW - back * DAY);
  const lunch = rand() < 0.4;
  d.setUTCHours(lunch ? int(1, 3) : int(7, 10), int(0, 59), int(0, 59), 0); // 11–14h / 17–21h AEST
  return d;
}

function writeEntry(key, author, place, when, opts = {}) {
  const lineCount = weighted([1, 2, 3, 4, 5, 6], (n) => ({ 1: 7, 2: 15, 3: 24, 4: 25, 5: 17, 6: 12 })[n]);
  const pool = [...place.menu];
  const dishes = [];
  while (dishes.length < Math.min(lineCount, pool.length)) {
    const m = weighted(pool, (x) => x.pop);
    pool.splice(pool.indexOf(m), 1);
    dishes.push(m);
  }

  let body = '';
  let placeQuery = null;
  let placeOffset = null;
  if (rand() < 0.72) {
    const t = fill(pick(D.OPENERS_PLACE));
    const at = t.indexOf('{P}');
    placeOffset = cp(t.slice(0, at));
    placeQuery = place.name;
    body = t.replace('{P}', place.name);
  } else {
    body = fill(pick(D.OPENERS_BARE));
  }

  const items = [];
  const unscoredRate = opts.unscoredRate ?? 0.15;
  const tagRate = opts.tagRate ?? 0.12;
  for (const m of dishes) {
    const lower = m.dish.toLowerCase();
    const style = rand();
    const mention = style < 0.5 ? lower : m.dish;
    const lead = style < 0.5 ? 'The ' : '';
    let score = rand() < unscoredRate ? null : halfStep(m.q + normal() * 0.5);
    if (score !== null && score >= 4.5 && m.q > 4.3 && rand() < (opts.sixRate ?? 0.035) && sixes < (opts.sixCap ?? 40)) {
      score = 6;
      sixes++;
    }
    const tags = m.tags.length && rand() < tagRate ? m.tags.filter(() => rand() < 0.7) : [];
    const tagText = tags.length ? ' ' + tags.map((t) => D.TAG_WORDS[t]).join(' ') : '';
    const sep = body === '' ? '' : ' ';
    let sentence;
    let evidence = null;
    let note = null;
    const mentionAt = cp(body) + cp(sep) + cp(lead);
    if (score === null) {
      note = pick(D.NOTES_NONE);
      sentence = `${lead}${mention}${tagText}, ${note}.`;
    } else {
      const was = rand() < 0.25;
      evidence = was ? `${mention} was a ${scoreText(score)}` : `${mention} ${scoreText(score)}`;
      note = rand() < 0.75 ? pick(score >= 4 ? D.NOTES_HIGH : score >= 3 ? D.NOTES_MID : D.NOTES_LOW) : null;
      sentence = `${lead}${evidence}${tagText}${note ? `, ${note}` : ''}.`;
    }
    body += sep + sentence;
    const item = { dish_name: m.dish, mention_text: mention, mention_offset: mentionAt, tags };
    if (score !== null) Object.assign(item, { score, score_evidence: evidence, evidence_offset: mentionAt });
    if (note) item.note = note;
    items.push(item);
  }
  return {
    id: uuid(`entry:${key}`), author: author.id ?? null, author_email: author.id ? null : author.email,
    restaurant: place.id, body, created_at: when.toISOString(), place_query: placeQuery, place_offset: placeOffset,
    items, photos: rand() < (opts.photoRate ?? 0.25) ? Array.from({ length: rand() < 0.6 ? 1 : 2 }, () => int(0, 9999)) : [],
    // for saves
    _dishes: dishes.map((m) => m.dish), _place: place, _author: author, _when: when,
  };
}

const entries = [];
const TARGET = 1500;
const totalW = users.reduce((s, u) => s + u.weight, 0);
for (const u of users) {
  const n = Math.max(3, Math.round((TARGET * u.weight) / totalW));
  for (let k = 0; k < n; k++) {
    const city = rand() < 0.88 ? u.home : pick(Object.keys(D.CITIES));
    let candidates = byCity[city];
    if (u.tastes && rand() < 0.7) {
      const liked = candidates.filter((r) => u.tastes.includes(r.cuisine));
      if (liked.length) candidates = liked;
    }
    const place = weighted(candidates, (r) => 1 / (r.rank + 3));
    entries.push(writeEntry(`${u.handle}:${k}`, u, place, drawDate()));
  }
}

// Eamon's 60: spread over cities, the whole 18 months, every score, some unscored, tags, a few 6s.
const EAMON = { email: 'eamon@ate.test', id: null, handle: 'eamon' };
const eamonPlan = [['melbourne', 34], ['sydney', 12], ['brisbane', 5], ['adelaide', 5], ['perth', 4]];
let ek = 0;
const eamonEntries = [];
for (const [city, n] of eamonPlan) {
  for (let k = 0; k < n; k++, ek++) {
    const place = pick(byCity[city]);
    const when = new Date(NOW - (Math.floor((ek + 0.5) * (SPAN_DAYS / 60)) + int(0, 5)) * DAY);
    when.setUTCHours(int(7, 10), int(0, 59), 0, 0);
    eamonEntries.push(writeEntry(`eamon:${ek}`, EAMON, place, when,
      { unscoredRate: 0.2, tagRate: 0.25, sixRate: ek % 20 === 7 ? 1 : 0, sixCap: 999, photoRate: 0.3 }));
  }
}
// Guarantee three 6s in Eamon's journal (the sixRate hook needs a high-quality dish; force if missing).
const eamonSixes = () => eamonEntries.flatMap((e) => e.items).filter((i) => i.score === 6).length;
for (const e of eamonEntries) {
  if (eamonSixes() >= 3) break;
  const it = e.items.find((i) => i.score >= 4.5);
  if (!it) continue;
  const old = it.score_evidence;
  const next = old.replace(/[0-9.]+$/, '6');
  e.body = e.body.replace(old, next);
  // same start; only the digits after it changed length, so later offsets shift by the difference
  const delta = cp(next) - cp(old);
  for (const other of e.items) {
    if (other.mention_offset > it.mention_offset) {
      other.mention_offset += delta;
      if (other.evidence_offset != null) other.evidence_offset += delta;
    }
  }
  it.score = 6;
  it.score_evidence = next;
}

// ---------------------------------------------------------------------------------------------------
// Saves
// ---------------------------------------------------------------------------------------------------
const saves = [];
const seen = new Set();
const everything = [...entries, ...eamonEntries];
function save(user, e, dish, at) {
  const key = `${user.id ?? user.email}|${e.restaurant}|${dish.toLowerCase()}`;
  if (seen.has(key)) return;
  seen.add(key);
  saves.push({ user: user.id ?? null, user_email: user.id ? null : user.email, restaurant: e.restaurant, dish_name: dish,
    source_entry: e.id, at: at.toISOString() });
}
for (const u of users) {
  const k = Math.round(8 + u.weight * 900);
  const others = everything.filter((e) => e._author !== u && (e._place.metro === u.home || rand() < 0.1));
  for (let i = 0; i < k && others.length; i++) {
    const e = pick(others);
    const at = new Date(Math.min(NOW - DAY, e._when.getTime() + int(1, 30) * DAY));
    save(u, e, pick(e._dishes), at);
  }
}
const theirs = entries.filter((e) => e._author !== EAMON);
for (let i = 0; i < 40; i++) {
  const e = pick(theirs);
  const at = new Date(Math.min(NOW - DAY, e._when.getTime() + int(1, 20) * DAY));
  save(EAMON, e, pick(e._dishes), at);
}

// ---------------------------------------------------------------------------------------------------
// SQL batches
// ---------------------------------------------------------------------------------------------------
const clean = (o) => Object.fromEntries(Object.entries(o).filter(([k]) => !k.startsWith('_') && k !== 'menu' && k !== 'rank'
  && k !== 'tastes' && k !== 'weight' && k !== 'home' && k !== 'metro'));
const batch = (fn, rows) => `select staging_seed.assert_staging();\n`
  + `select staging_seed.${fn}(x) from jsonb_array_elements($seed$${JSON.stringify(rows.map(clean))}$seed$::jsonb) x;\n`;
const chunks = (xs, n) => Array.from({ length: Math.ceil(xs.length / n) }, (_, i) => xs.slice(i * n, i * n + n));

const byDate = (a, b) => a.created_at.localeCompare(b.created_at);
const allEntries = [...entries, ...eamonEntries].sort(byDate); // oldest first: order numbers follow the calendar
const files = [
  ['00_setup.sql', readFileSync(join(HERE, 'setup.sql'), 'utf8')],
  ['01_users.sql', batch('put_user', users)],
  ...chunks(restaurants, 150).map((c, i) => [`02_restaurants_${i}.sql`, batch('put_restaurant', c)]),
  ...chunks(allEntries, 120).map((c, i) => [`03_entries_${String(i).padStart(2, '0')}.sql`, batch('put_entry', c)]),
  ...chunks(saves, 600).map((c, i) => [`04_saves_${i}.sql`, batch('put_save', c)]),
];

const lines = allEntries.flatMap((e) => e.items);
const counts = {
  users: users.length,
  restaurants: restaurants.length,
  restaurants_by_city: Object.fromEntries(Object.entries(byCity).map(([c, rs]) => [c, rs.length])),
  entries: entries.length,
  eamon_entries: eamonEntries.length,
  lines: lines.length,
  unscored_lines: lines.filter((i) => i.score == null).length,
  sixes: lines.filter((i) => i.score === 6).length,
  eamon_sixes: eamonSixes(),
  tagged_lines: lines.filter((i) => i.tags.length).length,
  entries_with_photos: allEntries.filter((e) => e.photos.length).length,
  saves: saves.length,
  eamon_saves: saves.filter((s) => s.user_email).length,
  distinct_saved_dishes: new Set(saves.map((s) => `${s.restaurant}|${s.dish_name.toLowerCase()}`)).size,
};

// ---------------------------------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------------------------------
const argv = new Set(process.argv.slice(2));
const out = process.env.SEED_OUT ?? mkdtempSync(join(tmpdir(), 'ate-seed-r6-'));
mkdirSync(out, { recursive: true });
for (const [name, sql] of files) writeFileSync(join(out, name), sql);
console.log(JSON.stringify({ out, files: files.length, ...counts }, null, 2));

function query(file) {
  const res = spawnSync('npx', ['-y', 'supabase', 'db', 'query', '--linked', '--project-ref', STAGING_REF,
    '--workdir', WORKDIR, '-f', file], { encoding: 'utf8', maxBuffer: 1 << 28 });
  if (res.status !== 0 || /"_tag":"Error"|ERROR/.test(res.stdout)) {
    throw new Error(`${file}: ${res.stdout}\n${res.stderr}`);
  }
  return res.stdout;
}

const linked = (() => {
  try { return readFileSync(join(WORKDIR, 'supabase', '.temp', 'project-ref'), 'utf8').trim(); } catch { return null; }
})();
if ((argv.has('--apply') || argv.has('--remove')) && linked !== null && linked !== STAGING_REF) {
  throw new Error(`the linked project is ${linked}, not staging (${STAGING_REF}) — refusing`);
}

if (argv.has('--remove')) {
  if (!argv.has('--i-mean-it')) throw new Error('--remove needs --i-mean-it');
  console.log(query(join(HERE, 'remove.sql')));
} else if (argv.has('--apply')) {
  query(join(out, '00_setup.sql'));
  console.log('removing any previous batch…');
  console.log(query(join(HERE, 'remove.sql')));
  for (const [name] of files.slice(1)) {
    process.stdout.write(`${name}… `);
    query(join(out, name));
    console.log('ok');
  }
}
