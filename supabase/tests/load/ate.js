// supabase/tests/load/ate.js — k6 load test of the app's own read/write paths. STAGING ONLY.
//
//   k6 run supabase/tests/load/ate.js                  ramp (default): 10 → 150 virtual users
//   PROFILE=smoke k6 run supabase/tests/load/ate.js     2 users for a minute, to check the script
//
// Each virtual user is one person using the app: opens Feed, reads their Journal, searches, opens a
// place, a profile and an entry, now and then logs an entry (and deletes it again). Think time
// between screens is 2–6 s, so 100 virtual users is roughly 100 people using the app at once.
//
// What it never calls: the edge functions. sort-entry/match-photos/dish-dedup spend Anthropic
// credit and places-search spends Google Places credit, and their scaling is Supabase's, not ours.
// Photos are not uploaded or downloaded (egress is the Free plan's scarcest quota).
//
// Safety: the URL is hard-coded to staging and the script refuses anything else. It signs in as the
// 60 seeded demo accounts (staging-seed), each once in setup(), and shares their tokens: Supabase
// rate-limits password sign-ins per IP. It aborts the whole run once responses get slow or start
// failing, so a run finds the knee without pushing staging over it for minutes, and it stops
// itself before its egress estimate passes EGRESS_BUDGET_MB.

import http from 'k6/http';
import exec from 'k6/execution';
import { check, sleep, group } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const STAGING = 'https://cvoitgoaosofkougmarn.supabase.co';
const KEY = 'sb_publishable_sMRFIanM38nujCu5o16Jeg_CWnDriNg'; // publishable: RLS is the boundary
const PASSWORD = 'atedemo123';
const HANDLES = [
  'noodlenerd', 'brunchbureau', 'the_dumpling_diaries', 'flatwhiteforever', 'saltandvinegar', 'laksa_lover_melb', 'crumbtrail', 'midweekmunchies',
  'spoonfed', 'okonomi_yaki_yes', 'currycartographer', 'pastapilgrim', 'tacotuesdayeveryday', 'the_hungry_accountant_melb', 'bakerybeforebreakfast',
  'sydneysizzle', 'bondibites', 'newtownnosh', 'harbourhunger', 'parramattaplates', 'brisbanebrunch', 'valleyvittles', 'adelaideappetite',
  'glenelggrazer', 'perthplates', 'freofeeds', 'jen_eats_everything', 'marcus_k', 'dan_the_dim_sum_man', 'soph',
];
const QUERIES = ['ramen', 'pho', 'pizza', 'dumpling', 'laksa', 'burger', 'taco', 'croissant', 'curry', 'gnocchi', 'bao', 'chicken', 'fitz', 'small', 'jo'];

const PROFILE = __ENV.PROFILE || 'ramp';
const EGRESS_BUDGET_MB = Number(__ENV.EGRESS_BUDGET_MB || 400);
const PEAK = Number(__ENV.PEAK || 200);

const profiles = {
  smoke: { stages: [{ duration: '1m', target: 2 }] },
  ramp: {
    stages: [
      { duration: '1m', target: 10 },
      { duration: '1m', target: 10 },
      { duration: '1m', target: Math.round(PEAK / 4) },
      { duration: '1m', target: Math.round(PEAK / 4) },
      { duration: '1m', target: Math.round(PEAK / 2) },
      { duration: '1m', target: Math.round(PEAK / 2) },
      { duration: '1m', target: PEAK },
      { duration: '1m', target: PEAK },
      { duration: '30s', target: 0 },
    ],
  },
};

export const options = {
  scenarios: { app: { executor: 'ramping-vus', startVUs: 1, gracefulRampDown: '10s', ...profiles[PROFILE] } },
  setupTimeout: '2m',
  thresholds: {
    // The circuit breakers: stop the run (and the load on staging) once the app would feel broken.
    http_req_failed: [{ threshold: 'rate<0.10', abortOnFail: true, delayAbortEval: '30s' }],
    'http_req_duration{kind:read}': [{ threshold: 'p(95)<4000', abortOnFail: true, delayAbortEval: '30s' }],
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

const bytesIn = new Counter('body_bytes_in');
const screen = new Trend('screen_ms', true);

export function setup() {
  if (!STAGING.includes('cvoitgoaosofkougmarn')) throw new Error('refusing: not staging');
  const users = [];
  for (const h of HANDLES) {
    const r = http.post(`${STAGING}/auth/v1/token?grant_type=password`,
      JSON.stringify({ email: `seed.${h}@ate.test`, password: PASSWORD }),
      { headers: { apikey: KEY, 'Content-Type': 'application/json' }, tags: { kind: 'auth' } });
    if (r.status === 200) users.push({ token: r.json('access_token'), id: r.json('user.id') });
    else console.warn(`sign-in ${h}: ${r.status} ${r.body}`);
  }
  if (users.length === 0) throw new Error('no demo account signed in');
  // A pool of real ids to open: places, people and entries from the global feed.
  const feed = rpc(users[0], 'get_entry_feed', { p_page_size: 50, p_include_own: true }, 'setup');
  const rows = feed.status === 200 ? feed.json() : [];
  return {
    users,
    places: [...new Set(rows.map((e) => e.restaurant_id ?? e.restaurant?.id).filter(Boolean))],
    authors: [...new Set(rows.map((e) => e.author_id ?? e.author?.id).filter(Boolean))],
    entries: rows.map((e) => e.id).filter(Boolean),
  };
}

function headers(user) {
  return { apikey: KEY, Authorization: `Bearer ${user.token}`, 'Content-Type': 'application/json' };
}

let myBytes = 0; // this VU's response bytes (k6 counters can't be read back in VU code)

function track(r, name) {
  const n = r.body ? r.body.length : 0;
  bytesIn.add(n);
  myBytes += n;
  check(r, { [`${name} ok`]: (x) => x.status >= 200 && x.status < 300 });
  return r;
}

function rpc(user, fn, params, kind = 'read') {
  const r = http.post(`${STAGING}/rest/v1/rpc/${fn}`, JSON.stringify(params ?? {}),
    { headers: headers(user), tags: { kind, name: fn } });
  return track(r, fn);
}

const pick = (xs) => xs[Math.floor(Math.random() * xs.length)];
const think = () => sleep(2 + Math.random() * 4);

// One "screen": its requests fire together, as the app's task groups do.
function screenOf(name, user, calls) {
  const t0 = Date.now();
  group(name, () => {
    const rs = http.batch(calls.map(([fn, p]) => ({
      method: 'POST', url: `${STAGING}/rest/v1/rpc/${fn}`, body: JSON.stringify(p ?? {}),
      params: { headers: headers(user), tags: { kind: 'read', name: fn } },
    })));
    rs.forEach((r, i) => track(r, calls[i][0]));
  });
  screen.add(Date.now() - t0, { screen: name });
}

export default function (data) {
  // Egress guard: this VU's share of the budget, then it idles for the rest of the run.
  const share = (EGRESS_BUDGET_MB * 1e6) / PEAK;
  if (myBytes > share) { sleep(30); return; }

  const user = data.users[exec.vu.idInTest % data.users.length];
  const roll = Math.random();

  if (roll < 0.35) {
    screenOf('feed', user, [
      ['get_entry_feed', { p_page_size: 20, p_include_own: false }],
      ['top_ate', { p_city: null, p_limit: 10 }],
      ['unread_notification_count', {}],
      ['feed_cities', {}],
    ]);
  } else if (roll < 0.55) {
    screenOf('journal', user, [
      ['my_entries', { p_sort: 'newest', p_limit: 20, p_tz: 'Australia/Melbourne' }],
      ['journal_days', { p_from: '2025-10-01', p_to: '2026-10-31', p_tz: 'Australia/Melbourne' }],
      ['my_entries_count', { p_tz: 'Australia/Melbourne' }],
    ]);
  } else if (roll < 0.75) {
    const q = pick(QUERIES);
    screenOf('search', user, [
      ['search_dishes', { p_query: q, p_limit: 20 }],
      ['search_places', { p_query: q, p_limit: 20 }],
      ['search_people', { p_query: q, p_limit: 20 }],
    ]);
  } else if (roll < 0.85 && data.places.length) {
    const id = pick(data.places);
    screenOf('place', user, [
      ['place_summary', { p_restaurant_id: id }],
      ['place_dishes', { p_restaurant_id: id, p_limit: 20 }],
      ['get_entries_at_place', { p_restaurant_id: id, p_scope: 'everyone', p_page_size: 20 }],
    ]);
  } else if (roll < 0.93 && data.authors.length) {
    const id = pick(data.authors);
    screenOf('profile', user, [
      ['profile_summary', { p_user_id: id }],
      ['get_entries_by_author', { p_author_id: id, p_page_size: 20 }],
    ]);
  } else if (roll < 0.98 && data.entries.length) {
    screenOf('entry', user, [['get_entry_card', { p_entry_id: pick(data.entries) }]]);
  } else if (data.places.length) {
    // Log an entry the way the composer does (insert, no sorter call), read it back, delete it.
    group('post', () => {
      const id = uuid();
      const r = http.post(`${STAGING}/rest/v1/entries`, JSON.stringify({
        id, author_id: user.id, body: 'Load test entry. Fried chicken 4. Noodles 3.5.',
        restaurant_id: pick(data.places),
      }), { headers: { ...headers(user), Prefer: 'return=minimal' }, tags: { kind: 'write', name: 'insert_entry' } });
      track(r, 'insert_entry');
      if (r.status < 300) {
        rpc(user, 'get_entry_card', { p_entry_id: id });
        rpc(user, 'delete_entry', { p_entry_id: id }, 'write');
      }
    });
  }
  think();
}

function uuid() {
  const h = '0123456789abcdef';
  let s = '';
  for (let i = 0; i < 36; i++) {
    if (i === 8 || i === 13 || i === 18 || i === 23) s += '-';
    else if (i === 14) s += '4';
    else if (i === 19) s += h[8 + Math.floor(Math.random() * 4)];
    else s += h[Math.floor(Math.random() * 16)];
  }
  return s;
}
