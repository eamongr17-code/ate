# Backend Integration — Design Spec

**Date:** 2026-06-10
**Status:** Approved design → ready for implementation plan
**Goal:** Turn Ate from a single-user, local-only app into a real multi-user product backed by Supabase — **without changing any screen or component**.

## Decisions (locked)

| Decision | Choice | Why |
| --- | --- | --- |
| Backend | **Supabase** (Postgres + Auth + Storage + RLS) | No server to run; security in the DB; generous free tier |
| Auth | **Apple + email/password** | Apple = native iOS + App Store requirement; email = Android / fallback |
| Sync model | **Optimistic + cache** | Keeps today's instant feel; zustand stays the client cache |
| Day-one content | **Empty slate** | No seed data; dishes/restaurants are user-generated on first review |
| Sequencing | **Thin core first** | Full schema up front; ship a testable slice fast, then layer on |

## Architecture

Nothing on screen changes. Screens read via selectors (`useFeed`, `useDiary`, …) and write via actions (`logReview`, `toggleLike`, …). We change only what is *behind* them.

```
screens → zustand store (cache + UI state) → src/data/api/* → Supabase
                  ↑ optimistic update           (thin query fns)     ↑ RLS-enforced
```

- **`src/data/supabase.ts`** — the Supabase client, configured from `EXPO_PUBLIC_SUPABASE_URL` + `EXPO_PUBLIC_SUPABASE_ANON_KEY` (the anon key is public-safe — RLS is what protects data, not key secrecy).
- **`src/data/api/`** — one thin module per concern (`profileApi`, `reviewsApi`, `socialApi`, `listsApi`, `storageApi`). Pure functions over the Supabase SDK; unit-testable by mocking the client.
- **Store actions** become: apply the change to local state immediately (instant feel) → call the API → on error, roll back the local change + surface a toast.
- **Bootstrap on launch (signed in):** fetch the user's slice (profile, diary, feed, lists) into the store. AsyncStorage remains a **warm cache** so the app opens instantly with last-known data, then refreshes from the server.
- **`src/data/auth.ts`** becomes real: `signInWithApple`, `signInWithPassword`, `signUp`, `signOut`, and an `onAuthStateChange` subscription. `useSession()` returns `null` when signed out.
- **`src/app/_layout.tsx`** gates on the session: `null` → auth screen; present → the app (the existing hydration gate composes with this).

### Why not React Query / a new server-state lib
The selector/action API already gives us a clean cache boundary; adding TanStack Query would mean rewriting how every screen *reads* data and would break the "screens don't change" guarantee. We extend the existing zustand actions instead. (YAGNI.)

## Schema (Postgres)

Empty slate means **dishes and restaurants are user-generated** — created/deduped on first review, not pre-seeded.

```sql
-- profiles: 1:1 with Supabase auth users
create table profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  username   citext unique not null,
  name       text not null,
  bio        text,
  avatar_url text,
  created_at timestamptz not null default now()
);

-- restaurants: user-generated, deduped by normalised name
create table restaurants (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  name_key   text generated always as (lower(btrim(name))) stored unique,
  city       text,
  cuisine    text,
  cover_url  text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

-- dishes: user-generated, deduped by name within a restaurant
create table dishes (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  restaurant_id uuid not null references restaurants(id) on delete cascade,
  name_key      text generated always as (lower(btrim(name))) stored,
  category      text,
  created_by    uuid references profiles(id),
  created_at    timestamptz not null default now(),
  unique (restaurant_id, name_key)
);

create table reviews (
  id         uuid primary key default gen_random_uuid(),
  author_id  uuid not null references profiles(id) on delete cascade,
  dish_id    uuid not null references dishes(id) on delete cascade,
  score      numeric(2,1) not null check (score >= 0 and score <= 5),
  note       text,
  photo_url  text,
  created_at timestamptz not null default now()
);
create index on reviews (author_id, created_at desc);
create index on reviews (dish_id);

create table follows (
  follower_id uuid not null references profiles(id) on delete cascade,
  followee_id uuid not null references profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);

create table likes (
  user_id   uuid not null references profiles(id) on delete cascade,
  review_id uuid not null references reviews(id) on delete cascade,
  primary key (user_id, review_id)
);

create table comments (
  id         uuid primary key default gen_random_uuid(),
  review_id  uuid not null references reviews(id) on delete cascade,
  author_id  uuid not null references profiles(id) on delete cascade,
  text       text not null,
  created_at timestamptz not null default now()
);
create index on comments (review_id, created_at);

create table comment_likes (
  user_id    uuid not null references profiles(id) on delete cascade,
  comment_id uuid not null references comments(id) on delete cascade,
  primary key (user_id, comment_id)
);

create table saved_reviews (
  user_id   uuid not null references profiles(id) on delete cascade,
  review_id uuid not null references reviews(id) on delete cascade,
  primary key (user_id, review_id)
);

create table lists (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references profiles(id) on delete cascade,
  name        text not null,
  description text,
  cover_url   text,
  created_at  timestamptz not null default now()
);

create table list_dishes (
  list_id  uuid not null references lists(id) on delete cascade,
  dish_id  uuid not null references dishes(id) on delete cascade,
  added_at timestamptz not null default now(),
  primary key (list_id, dish_id)
);
```

### Derived data — no stale counters
Counts are computed, never stored:
- A review's **like/comment counts** and the viewer's **liked/saved** flags ride along on the query via Supabase embedded aggregates:
  `reviews?select=*,likes(count),comments(count),liked:likes!inner(user_id)` (filtered to `auth.uid()` for the flag).
- A dish's **avg score / review count** → `avg(score)` / `count(*)` over its reviews.
- A profile's **follower/following counts** → `count(*)` over `follows`.

### Feed = one SQL function
```sql
create or replace function get_feed(before timestamptz default now(), limit_n int default 50)
returns setof reviews language sql stable as $$
  select r.* from reviews r
  join follows f on f.followee_id = r.author_id
  where f.follower_id = auth.uid() and r.created_at < before
  order by r.created_at desc
  limit limit_n;
$$;
```

### Row-Level Security (the safety net)
RLS is enabled on every table; the database — not the app — enforces ownership.

| Table | SELECT | INSERT | UPDATE / DELETE |
| --- | --- | --- | --- |
| profiles | all | self (`id = auth.uid()`) | self |
| restaurants, dishes | all | any authed user | creator only (or none) |
| reviews | all | author (`author_id = auth.uid()`) | author only |
| comments | all | author | author only |
| follows, likes, comment_likes, saved_reviews | all (or per-need) | the acting user | the acting user |
| lists | all (shareable) | owner | owner |
| list_dishes | all | list owner | list owner |

Canonical pattern:
```sql
alter table reviews enable row level security;
create policy reviews_read   on reviews for select using (true);
create policy reviews_insert on reviews for insert with check (author_id = auth.uid());
create policy reviews_modify on reviews for update using (author_id = auth.uid());
create policy reviews_delete on reviews for delete using (author_id = auth.uid());
```

### Storage
Two buckets: `review-photos` and `avatars`. The existing `expo-image-picker` flow yields a local URI → `storageApi.upload()` → public URL stored on the review/profile. Insert policy: an authed user may upload only under their own `auth.uid()/…` path.

### New-user provisioning
On first sign-up, a Postgres trigger creates the matching `profiles` row from `auth.users` (username chosen at sign-up, validated unique). Sign-up screen enforces username availability before submit.

## Auth flow
- Email/password works immediately (Supabase Auth) — this is what Slice 1 ships with.
- **Sign in with Apple** is added alongside TestFlight, when an Apple Developer account + Services ID exist (it can't be exercised in the simulator without that setup).
- Session gating: `useSession()` null → the app renders the auth screen; present → the tab app. `onAuthStateChange` keeps it live across token refresh / sign-out.

## Client changes (file-by-file)
- **add** `src/data/supabase.ts` — client + env.
- **add** `src/data/api/{profile,reviews,social,lists,storage}.ts` — query functions.
- **edit** `src/data/auth.ts` — real Supabase auth + session subscription.
- **edit** `src/data/store.ts` — drop the seeded initial state (empty arrays until fetched); add `bootstrap()` to hydrate from the server on auth; make each action optimistic with rollback. Selector/action **signatures stay identical**.
- **edit** `src/data/types.ts` — minor: ids stay `string` (uuids); `Dish` gains `restaurantId`; `photo`/`avatar` become URLs.
- **demote** `src/data/fixtures.ts` — test-only seed (no longer the runtime source).
- **edit** `src/app/_layout.tsx` — session gate.
- **add** a **minimal functional auth screen** (`src/app/(auth)/…`) composed from existing components (Wordmark, Input, Button) so the core loop is testable. Polished onboarding is the separate Auth track.
- **add** `.env` handling (`EXPO_PUBLIC_SUPABASE_URL`, `EXPO_PUBLIC_SUPABASE_ANON_KEY`) + `app.config` wiring.

### Optimistic update pattern (one helper, used by every action)
```
1. snapshot the slice being changed
2. apply the new value to the store immediately
3. await api.call()
4. on error: restore the snapshot + toast "Couldn't save — try again"
```

## Build slices (thin core first)
**Slice 1 — Core loop (first build on a real phone):** schema for profiles/restaurants/dishes/reviews + RLS + Storage; `supabase.ts`; real `auth.ts` (email/password) + minimal auth screen; profile load/edit + avatar upload; `logReview` (upsert restaurant+dish, insert review, upload photo); diary + dish page from the server; store bootstrap.

**Slice 2 — Social:** follows, `get_feed`, likes, comments, comment_likes + RLS; wire `toggleFollow`/`useFeed`/`toggleLike`/`addComment`/`toggleCommentLike`; server-backed search (people/dishes/restaurants).

**Slice 3 — Lists & sharing:** lists, list_dishes, saved_reviews + RLS; `createList`/`toggleDishInList`/`deleteList`/`toggleSaveReview`; real shareable list links (deep link).

## Testing
- **API layer** — unit tests with a mocked Supabase client (request shape + response mapping).
- **Store** — extend the existing integration tests: optimistic apply, rollback on simulated API error, bootstrap hydration.
- **End-to-end** — a Maestro flow against a real Supabase **test project**: sign up → log a dish → see it in diary → (Slice 2) follow + feed. Runs on a throwaway account.
- `tsc` + the full `jest` suite stay green at every step.

## Places integration — edge function contract (`places-search`)

> Added 2026-06-16 (PH-BE-1 + PH-BE-2). The `places-search` edge function is the
> ONLY way the client talks to Google Places. `verify_jwt: true` — every call
> needs a valid user JWT. Function file: `supabase/functions/places-search/index.ts`.
> Stub mode (no `GOOGLE_PLACES_API_KEY`) serves the same shapes from fixtures.

**Hardening rules (Eamon-locked 2026-06-16), applied across the ops:**
- **VIC-only (PH-E1, hardened by the PH-BE-1+2 peer review).** Autocomplete sends
  `locationRestriction.rectangle` = VIC bounding box (low `-39.2,140.96` → high
  `-33.98,149.98`; the `-39.2` south bound reaches Wilsons Promontory and covers
  Melbourne/Geelong — an earlier `-37.5` sat north of Melbourne and returned 0
  predictions) + `includedRegionCodes:['au']`; nearby uses a circle restriction
  (searchNearby has no rectangle form). The rectangle/circle is the hard
  containment — results are constrained to the VIC box, not merely biased. On top
  of that, BOTH ops apply a **server-side border-bleed drop**: a result is removed
  ONLY when its address/secondary text **positively names another AU
  state/territory** — `\b(NSW|QLD|SA|WA|NT|TAS|ACT)\b` (word-anchored so "WA"
  doesn't match WARRNAMBOOL, "SA" doesn't match SALE) or the full state names. A
  result with **no** state token (e.g. "Melbourne, Australia" / "Fitzroy,
  Australia") is **KEPT** — the box already guarantees it's in VIC, and Google
  routinely omits the state in autocomplete secondary text. (The earlier
  *require-VIC* rule silently dropped legitimate Melbourne venues → empty
  predictions → `RestaurantNotFoundError`; this inversion fixes that false
  negative while still dropping clear border-bleed like "Albury, NSW, Australia".)
- **Food/bev only (PH-E2).** Autocomplete uses 5 `includedPrimaryTypes`
  (`restaurant, cafe, bar, bakery, meal_takeaway`) — the Places API (New)
  autocomplete cap. Nearby uses the broader `includedTypes` set (24 verified
  food/bev Table-A types; searchNearby allows up to 50).
- **Caps (PH-E3).** Typed autocomplete → max **5** predictions. Nearby default
  list → max **10**. Enforced server-side; the FE also slices.
- **No photos (BE-PLACES-1).** No `photos` in any field mask. `cover_url` stays `''`.
- **Session tokens (BE-PLACES-3).** `session_token` in the autocomplete/details
  body bills the keystrokes + the resolve as one session.
- **Known-place short-circuit (BE-PLACES-4).** `op=details` returns an existing
  `restaurants` row by `google_place_id` without any paid Google call.

| op | method | request body | response | notes |
| --- | --- | --- | --- | --- |
| `autocomplete` | POST `?op=autocomplete` | `{ input: string, lat?: number, lng?: number, session_token?: string }` | `{ stub: bool, predictions: [{ google_place_id, name, secondary, distance_meters? }] }` | VIC-only, food/bev, ≤5. **FB2-BE-1:** when BOTH `lat`+`lng` are sent (finite numbers), they're forwarded to Google as `origin` and each prediction carries `distance_meters` (metres from the origin). Omitted when no origin (back-compat). VIC restriction + ranking otherwise unchanged. |
| `details` | POST `?op=details` | `{ google_place_id: string, session_token?: string }` | `{ stub: bool, restaurant: { id, google_place_id, name, address, city, cuisine, cover_url } }` | Upserts the `restaurants` row (the only restaurant-create path). 404 if not found. |
| `nearby` | POST `?op=nearby` | `{ lat: number, lng: number, radius?: number }` | `{ stub: bool, source: 'db'\|'google'\|'blend', restaurants: [{ id, google_place_id, name, address, city, cuisine, cover_url, distance_meters? }] }` | **NEW.** PostGIS-first KNN via the `restaurants_nearby` RPC (data-model §5, migration 0005); Google `searchNearby` fallback only when DB rows < 5; upserts Google results; deduped by `google_place_id`; VIC-filtered; ≤10. `radius` defaults to 2000 m, clamped 100–50000 m. **FB2-BE-1:** each row carries `distance_meters` — the RPC's `distance_m` (DB rows) or a haversine from the query origin (Google-fallback rows), in metres. |

**Contract notes for the FE:**
- The `autocomplete` and `details` response shapes are **back-compat** — existing
  client code keeps working; the only autocomplete change is the **additive**
  `distance_meters?` field on each prediction.
- **`distance_meters` (FB2-BE-1, additive — both ops):** an optional `number` in
  metres on autocomplete predictions and nearby rows. The FE shows "name +
  distance (km)" by dividing by 1000 (e.g. `1234 → "1.2 km"`). It is **present
  only when the server can compute it**:
  - *autocomplete* → only when the request sent BOTH finite `lat`+`lng` (the
    origin). No origin sent → no `distance_meters` on any prediction. Send the
    device location to get distances.
  - *nearby* → DB rows always carry it (the RPC computes it); Google-fallback
    rows carry a haversine from the query origin. (Both paths have an origin, so
    it is effectively always present on nearby rows in live mode.)
  - The FE must treat it as optional and fall back gracefully (no distance shown)
    when absent — never assume it's present.
  - **Wire field name is `distance_meters` (snake_case)** — matches the existing
    wire convention (`google_place_id`, `cover_url`, `secondary`) and the FE
    consumer, which reads `distance_meters`. (Google's own autocomplete field is
    camelCase `distanceMeters`; the function reads that from Google and re-emits it
    under the snake_case key — do not confuse the two.)
- `op=nearby` is **additive** — a new op, a new response shape (`source` +
  `restaurants[]`). The `restaurants[]` rows match the `op=details` `restaurant`
  shape plus the optional `distance_meters`, so the picker can render nearby rows
  with the same component.
- **`nearby.id` GUARANTEE (live mode):** whenever `stub` is `false` — i.e.
  `source` is `'db'`, `'google'`, or `'blend'` — every `restaurants[].id` IS a
  real, writable `restaurants.id` UUID. The FE can write a review against that
  `id` **directly**, with no `op=details` round-trip. (Google-fallback rows are
  upserted server-side *before* the response is built, so they already carry our
  UUID.) **Stub-mode only:** when `stub` is `true`, no UUID exists offline, so
  `id` is the fixture `google_place_id` instead — in that one case the client
  must resolve via `op=details` (`google_place_id`) before writing. Net: trust
  `nearby.id` as a row id in live mode; treat it as a place id only when
  `stub === true`.
- **Empty result (`restaurants: []`):** a `200` with an empty `restaurants[]`
  and *any* `source` value means "nothing nearby" — the FE renders an empty
  state, not an error. (It is not an error condition; `source` is still set.)
- **`source` derivation (observability, not a contract switch):**
  - `'db'` — served entirely from PostGIS (the `restaurants_nearby` KNN RPC); the
    DB had ≥ 5 nearby rows, so **no Google call was made** (free, fast path).
  - `'google'` — the DB had **zero** nearby rows; the list came solely from the
    Google `searchNearby` fallback (results upserted, so they carry UUIDs).
  - `'blend'` — the DB had **some** (1–4) nearby rows but below the threshold, so
    Google was queried to top up; the response merges DB-first (KNN order) then
    the new Google rows, deduped by `google_place_id`.
  The FE renders all three identically; `source` is a debugging/telemetry signal.

## What's yours vs. mine
- **You:** create the Supabase project (free, ~5 min); paste the schema/RLS SQL I provide into the SQL editor; hand me the project URL + anon key (config, not a secret). Apple Developer setup only when we reach TestFlight.
- **Me:** all schema/RLS/function SQL, the client, the API layer, the store rewrite, `auth.ts`, the minimal auth screen, and every test.

## Out of scope (MVP)
Real-time feed updates (use pull-to-refresh), push notifications, blocking/moderation, a places API for restaurant autocomplete, full offline write-queue, and the polished onboarding design (separate Auth track).

## Risks / open items
- **Auth screen dependency:** the core loop needs a way to sign in; Slice 1's minimal screen covers it, but if you'd rather design onboarding first, that reorders things.
- **Dish/restaurant dedup** is name-based (case/space-normalised). Good enough for MVP; a places API would harden it later.
- **Apple Sign In** can't be tested until the Apple Developer account exists — email/password carries Slice 1 testing until then.
