-- 0060_lists_and_journal_search.sql
-- Ate backend — CUSTOM LISTS + JOURNAL SEARCH. DRAFT — authored and tested locally (PGlite); not applied
-- anywhere. Lands through a PR like every migration (staging after QA, prod by the CI job).
--
-- LISTS (Eamon, 5 Oct 2026). A user names a list ("Fitzroy's greatest beers"), picks dishes from THEIR
--   OWN entries and orders them by hand. Never auto-generated. Private to the owner (V1); the image
--   share is rendered on the phone — no server work.
--
-- WHY NEW TABLES, NOT THE LEGACY `lists` / `list_dishes` (0002/0003/0004). They look reusable and are
--   not:
--   * `lists` HOLDS ROWS: handle_new_user (0005 → 0032 → 0035, still live) inserts a system "Saved"
--     list for EVERY user at sign-up, and `list_dishes` may hold the old Expo build's saves (0020 moved
--     V1 saves to `saves` and left these "applied and untouched"). Reusing the table means every read
--     filters `is_system` forever; dropping it destroys rows nobody has counted on prod (a CEO
--     escalation, rule 4d) and needs handle_new_user, merge_dish and delete_account rewritten together.
--   * its policies are `select using (true)` — PUBLIC to every signed-in user. A private list on that
--     table is one forgotten policy away from a leak.
--   * the grain is wrong: `list_dishes` is keyed (list_id, dish_id) — a catalogue dish, not the user's
--     line — so it cannot carry "my 4.5 at Tipo on 3 Sept" and cannot be removed when that line goes.
--   So the legacy pair stays exactly as it is (dormant), and a later migration can drop it once the
--   prod row counts have been looked at and the drop has been escalated. Nothing here touches it.
--
-- THE ITEM GRAIN: (entry_id, dish_id) — "the dish line of this visit", NOT reviews.id.
--   * a re-sort (`apply_entry_sort`, forced after a body edit) DELETES and re-inserts every uncorrected
--     line, so a review id does not survive an edit. (entry, dish) does: the rebuilt line resolves to
--     the same dish (`find_or_create_dish` by name at the place).
--   * the line's dish CHANGING (correct_entry_dish, correct_entry_place re-resolving at a new place,
--     merge_dish) carries the item to the new dish (trigger, immediate).
--   * the line GONE — deleted by its author, or not rebuilt by a re-sort — removes the item. The check is
--     a DEFERRED constraint trigger, run at COMMIT, so a re-sort's delete-then-reinsert inside one
--     transaction never drops it. Entry deleted → FK cascade. Dish deleted → FK cascade.
--   * two visits of the same dish are two items (sittings are a feature); one (entry, dish) appears at
--     most once per list — UNIQUE (list_id, entry_id, dish_id), TOTAL.
--   * a pre-entries line (reviews.entry_id NULL) cannot be listed: it has no visit to point at.
--
-- ─── Storage (RLS on both; SELECT own; NO client write grant — every write is an RPC below)
--   user_lists (id, owner_id, name, visibility, created_at, updated_at). visibility CHECK = 'private' only,
--     default 'private': a later "public" flag is ADDITIVE (widen the CHECK + add a SELECT policy).
--     ≤ 50 per owner. name trimmed, 1–80 characters.
--   user_list_items (id, list_id, owner_id, entry_id, dish_id, position, added_at). position 1…n, kept
--     DENSE (every write renumbers), ≤ 100 per list. owner_id is denormalised for RLS and delete_account.
--
-- ─── RPCs (all ADDITIVE, signed in only)
--   create_list(p_name) · rename_list(p_list_id, p_name) · delete_list(p_list_id)
--   add_list_item(p_list_id, p_entry_id, p_dish_id) · remove_list_item(p_item_id)
--   reorder_list(p_list_id, p_item_ids) — the FULL ordered id array
--   my_lists(p_limit, p_cursor_created_at, p_cursor_id) · get_list(p_list_id)
--   my_lists_for_dish_line(p_entry_id, p_dish_id) · my_scored_dishes(p_query, …)
--
-- JOURNAL SEARCH. search_my_entries(p_query, p_limit, p_cursor_created_at, p_cursor_id) → setof
--   entry_cards, the caller's OWN entries whose words, place name or any line's dish name contain the
--   query; the Journal's order (created_at, id) DESC and keyset.
--   pg_trgm, not tsvector: (1) it is the app's one search semantic already — `search_key()` (0031: trim,
--   unaccent, lower) substring, so "ragu" finds "ragù" here exactly as it does on the Search tab; (2)
--   prefix AND mid-word ("burg", "margh", "bánh") match, where a tsvector needs whole lexemes and a
--   language config whose stemmer mangles Italian/Vietnamese dish names; (3) nothing denormalised to keep
--   in step with re-sorts, corrections and renames — dish and place names are read live, and
--   their search_key trigram indexes already exist (0031). The one new index is a trigram GIN on
--   search_key(entries.body). Scale: the read is bounded by entries_author_idx (a few thousand rows per
--   user, walked newest-first and stopping at the page); for a rare term the planner can BitmapAnd the
--   body trigram index with it instead.
--
-- WIRE IMPACT: ADDITIVE — two tables, new RPCs, one index. delete_account's body is 0058's plus the two
--   new tables in its "nothing survived" check (same signature, same reply). Nothing existing changes.

set search_path = public, extensions;

-- ===========================================================================
-- 1. Tables.
-- ===========================================================================
create table if not exists public.user_lists (
  id          uuid        primary key default gen_random_uuid(),
  owner_id    uuid        not null references public.profiles(id) on delete cascade,
  name        text        not null,
  visibility  text        not null default 'private',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint user_lists_name_ck       check (name = btrim(name) and char_length(name) between 1 and 80),
  constraint user_lists_visibility_ck check (visibility in ('private'))
);
create index if not exists user_lists_owner_idx on public.user_lists (owner_id, created_at desc, id desc);

create table if not exists public.user_list_items (
  id        uuid        primary key default gen_random_uuid(),
  list_id   uuid        not null references public.user_lists(id) on delete cascade,
  owner_id  uuid        not null references public.profiles(id)   on delete cascade,
  entry_id  uuid        not null references public.entries(id)    on delete cascade,
  dish_id   uuid        not null references public.dishes(id)     on delete cascade,
  position  int         not null,
  added_at  timestamptz not null default now(),
  constraint user_list_items_position_ck check (position >= 1),
  constraint user_list_items_line_uq     unique (list_id, entry_id, dish_id)     -- TOTAL
);
create index if not exists user_list_items_list_idx  on public.user_list_items (list_id, position, id);
create index if not exists user_list_items_line_idx  on public.user_list_items (entry_id, dish_id);
create index if not exists user_list_items_dish_idx  on public.user_list_items (dish_id);
create index if not exists user_list_items_owner_idx on public.user_list_items (owner_id);

-- Journal search: the words, accent-folded (dish + place names already have theirs, 0031).
create index if not exists entries_body_search_trgm
  on public.entries using gin (public.search_key(body) extensions.gin_trgm_ops);

comment on table public.user_lists is
  'Custom lists (0060): a named, hand-ordered list of the owner''s own dish lines. Private (visibility CHECK = private; a public flag is additive). ≤ 50 per owner. Owner-only SELECT; written by RPCs.';
comment on table public.user_list_items is
  'A list item (0060) = one dish line of one of the owner''s visits: (entry_id, dish_id), not a review id, so it survives a re-sort. Follows a dish correction; removed at commit when that entry no longer has a line for the dish. position dense 1…n, ≤ 100 per list.';

-- ===========================================================================
-- 2. RLS + grants. Owner reads; nobody writes but the RPCs (DEFINER).
-- ===========================================================================
alter table public.user_lists      enable row level security;
alter table public.user_list_items enable row level security;

drop policy if exists user_lists_select_own on public.user_lists;
create policy user_lists_select_own on public.user_lists
  for select to authenticated using (owner_id = (select auth.uid()));
drop policy if exists user_list_items_select_own on public.user_list_items;
create policy user_list_items_select_own on public.user_list_items
  for select to authenticated using (owner_id = (select auth.uid()));

revoke all on public.user_lists, public.user_list_items from anon, authenticated;
grant select on public.user_lists, public.user_list_items to authenticated;
grant all    on public.user_lists, public.user_list_items to service_role;

-- ===========================================================================
-- 3. Items follow their line (triggers on reviews).
-- ===========================================================================
-- A line's dish changed (a correction, a place re-resolve, a merge): carry the items to the new dish once
-- no line on that entry carries the old one. If the list already holds (entry, new dish), the old item is
-- the duplicate and goes. Immediate, so a read in the same transaction already sees it.
create or replace function public.trg_list_items_follow_dish()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  v_lists uuid[];
begin
  if exists (select 1 from public.reviews r where r.entry_id = old.entry_id and r.dish_id = old.dish_id) then
    return null;
  end if;
  with dup as (
    delete from public.user_list_items i
    where i.entry_id = old.entry_id and i.dish_id = old.dish_id
      and exists (select 1 from public.user_list_items j
                  where j.list_id = i.list_id and j.entry_id = old.entry_id and j.dish_id = new.dish_id)
    returning i.list_id
  )
  select array_agg(distinct list_id) into v_lists from dup;
  update public.user_list_items i set dish_id = new.dish_id
  where i.entry_id = old.entry_id and i.dish_id = old.dish_id;
  if v_lists is not null then
    perform public.list_renumber(l) from unnest(v_lists) l;
  end if;
  return null;
end; $$;

-- The line is gone: at COMMIT, drop the items whose (entry, dish) has no line left. Deferred so a re-sort
-- (delete every uncorrected line, insert the rebuilt ones — one transaction) never loses an item whose
-- dish the rebuilt receipt still prints. Positions are renumbered so they stay 1…n.
create or replace function public.trg_list_items_line_gone()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  v_lists uuid[];
begin
  if exists (select 1 from public.reviews r where r.entry_id = old.entry_id and r.dish_id = old.dish_id) then
    return null;
  end if;
  with gone as (
    delete from public.user_list_items i
    where i.entry_id = old.entry_id and i.dish_id = old.dish_id
    returning i.list_id
  )
  select array_agg(distinct list_id) into v_lists from gone;
  if v_lists is not null then
    perform public.list_renumber(l) from unnest(v_lists) l;
  end if;
  return null;
end; $$;

-- Dense positions 1…n in the current order (≤ 100 rows).
create or replace function public.list_renumber(p_list_id uuid)
returns void language sql volatile security definer set search_path = public, extensions as $$
  update public.user_list_items i set position = o.rn
  from (select id, row_number() over (order by position, added_at, id)::int rn
        from public.user_list_items where list_id = p_list_id) o
  where i.id = o.id and i.position <> o.rn;
$$;

drop trigger if exists reviews_list_items_follow_dish on public.reviews;
create trigger reviews_list_items_follow_dish
  after update of dish_id on public.reviews
  for each row
  when (old.entry_id is not null and old.dish_id is distinct from new.dish_id)
  execute function public.trg_list_items_follow_dish();

drop trigger if exists reviews_list_items_line_gone on public.reviews;
create constraint trigger reviews_list_items_line_gone
  after delete or update of dish_id, entry_id on public.reviews
  deferrable initially deferred
  for each row
  when (old.entry_id is not null)
  execute function public.trg_list_items_line_gone();

revoke all on function public.trg_list_items_follow_dish() from public, anon, authenticated;
revoke all on function public.trg_list_items_line_gone()   from public, anon, authenticated;
revoke all on function public.list_renumber(uuid)          from public, anon, authenticated;

-- ===========================================================================
-- 4. Helpers.
-- ===========================================================================
-- The caller's list, row-locked (serialises the item cap and the renumbering), or a raise. A list that is
-- not yours reads exactly like one that does not exist: P0002.
create or replace function public.list_own(p_list_id uuid)
returns public.user_lists language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid  uuid := (select auth.uid());
  v_list public.user_lists;
begin
  if v_uid is null then
    raise exception 'sign in to use lists' using errcode = '42501';
  end if;
  select * into v_list from public.user_lists where id = p_list_id and owner_id = v_uid for update;
  if not found then
    raise exception 'list_not_found' using errcode = 'P0002';
  end if;
  return v_list;
end; $$;

-- A list name: trimmed, 1–80 characters, else 22023.
create or replace function public.list_name(p_name text)
returns text language plpgsql immutable set search_path = public, extensions as $$
declare
  v text := btrim(coalesce(p_name, ''));
begin
  if char_length(v) = 0 or char_length(v) > 80 then
    raise exception 'bad_list_name' using errcode = '22023';
  end if;
  return v;
end; $$;

-- The photo an item shows: the line's own photo, else its visit's first photo (which may picture another
-- dish of that visit — get_dish_reviews' rule), else null. Never another person's photo.
create or replace function public.list_item_photo(p_entry_id uuid, p_dish_id uuid)
returns text language sql stable security invoker set search_path = public, extensions as $$
  select coalesce(
    (select r.photo_url from public.reviews r
     where r.entry_id = p_entry_id and r.dish_id = p_dish_id and r.photo_url is not null
     order by r.entry_position nulls last, r.id limit 1),
    (select p.photo_url from public.entry_photos p where p.entry_id = p_entry_id order by p.position limit 1));
$$;

-- The line an item stands for (the first if a visit printed the dish twice): its score.
create or replace function public.list_item_score(p_entry_id uuid, p_dish_id uuid)
returns numeric language sql stable security invoker set search_path = public, extensions as $$
  select r.score from public.reviews r
  where r.entry_id = p_entry_id and r.dish_id = p_dish_id
  order by r.entry_position nulls last, r.id limit 1;
$$;

revoke all on function public.list_own(uuid)                 from public, anon, authenticated;
revoke all on function public.list_name(text)                from public, anon, authenticated;
revoke all on function public.list_item_photo(uuid, uuid)    from public, anon;
revoke all on function public.list_item_score(uuid, uuid)    from public, anon;
grant execute on function public.list_item_photo(uuid, uuid) to authenticated, service_role;
grant execute on function public.list_item_score(uuid, uuid) to authenticated, service_role;

-- ===========================================================================
-- 5. List writes.
-- ===========================================================================
create or replace function public.create_list(p_name text)
returns table (list_id uuid, name text, visibility text, item_count int, created_at timestamptz, updated_at timestamptz)
language plpgsql volatile security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare
  v_uid  uuid := (select auth.uid());
  v_name text;
  v_list public.user_lists;
begin
  if v_uid is null then
    raise exception 'sign in to use lists' using errcode = '42501';
  end if;
  v_name := public.list_name(p_name);
  -- serialise per owner so two parallel creates cannot pass 50
  perform pg_advisory_xact_lock(hashtextextended('user_lists:' || v_uid::text, 0));
  if (select count(*) from public.user_lists l where l.owner_id = v_uid) >= 50 then
    raise exception 'list_cap' using errcode = '54000';
  end if;
  insert into public.user_lists (owner_id, name) values (v_uid, v_name) returning * into v_list;
  return query select v_list.id, v_list.name, v_list.visibility, 0, v_list.created_at, v_list.updated_at;
end; $$;

create or replace function public.rename_list(p_list_id uuid, p_name text)
returns table (list_id uuid, name text, visibility text, item_count int, created_at timestamptz, updated_at timestamptz)
language plpgsql volatile security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare
  v_list public.user_lists := public.list_own(p_list_id);
  v_name text := public.list_name(p_name);
begin
  update public.user_lists l set name = v_name, updated_at = now() where l.id = v_list.id returning * into v_list;
  return query select v_list.id, v_list.name, v_list.visibility,
    (select count(*)::int from public.user_list_items i where i.list_id = v_list.id),
    v_list.created_at, v_list.updated_at;
end; $$;

-- 1 deleted · 0 already gone or not yours (treat as done). Its items go with it.
create or replace function public.delete_list(p_list_id uuid)
returns int language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid uuid := (select auth.uid());
  v_n   int;
begin
  if v_uid is null then
    raise exception 'sign in to use lists' using errcode = '42501';
  end if;
  delete from public.user_lists where id = p_list_id and owner_id = v_uid;
  get diagnostics v_n = row_count;
  return v_n;
end; $$;

-- Append one of YOUR dish lines. Idempotent: the same (entry, dish) again returns the existing item.
create or replace function public.add_list_item(p_list_id uuid, p_entry_id uuid, p_dish_id uuid)
returns table (item_id uuid, list_id uuid, entry_id uuid, dish_id uuid, item_position int, added_at timestamptz)
language plpgsql volatile security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare
  v_list public.user_lists := public.list_own(p_list_id);
  v_item public.user_list_items;
begin
  select * into v_item from public.user_list_items i
  where i.list_id = v_list.id and i.entry_id = p_entry_id and i.dish_id = p_dish_id;
  if found then
    return query select v_item.id, v_item.list_id, v_item.entry_id, v_item.dish_id, v_item.position, v_item.added_at;
    return;
  end if;
  if not exists (
    select 1 from public.entries e join public.reviews r on r.entry_id = e.id
    where e.id = p_entry_id and e.author_id = v_list.owner_id and r.dish_id = p_dish_id
  ) then
    raise exception 'dish_line_not_found' using errcode = 'P0002';
  end if;
  if (select count(*) from public.user_list_items i where i.list_id = v_list.id) >= 100 then
    raise exception 'list_item_cap' using errcode = '54000';
  end if;
  insert into public.user_list_items (list_id, owner_id, entry_id, dish_id, position)
  values (v_list.id, v_list.owner_id, p_entry_id, p_dish_id,
          coalesce((select max(i.position) from public.user_list_items i where i.list_id = v_list.id), 0) + 1)
  returning * into v_item;
  update public.user_lists l set updated_at = now() where l.id = v_list.id;
  return query select v_item.id, v_item.list_id, v_item.entry_id, v_item.dish_id, v_item.position, v_item.added_at;
end; $$;

-- 1 removed · 0 already gone or not yours. The rest close ranks (positions stay 1…n).
create or replace function public.remove_list_item(p_item_id uuid)
returns int language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid  uuid := (select auth.uid());
  v_list uuid;
begin
  if v_uid is null then
    raise exception 'sign in to use lists' using errcode = '42501';
  end if;
  select i.list_id into v_list from public.user_list_items i where i.id = p_item_id and i.owner_id = v_uid;
  if v_list is null then
    return 0;
  end if;
  perform public.list_own(v_list);                 -- lock the list: serialise with reorder/add
  delete from public.user_list_items where id = p_item_id;
  perform public.list_renumber(v_list);
  update public.user_lists set updated_at = now() where id = v_list;
  return 1;
end; $$;

-- The whole order in one call: p_item_ids must be EXACTLY the list's items (each once), in the new order;
-- anything else (a stale client, an item removed meanwhile) → 22023 reorder_mismatch → refetch get_list.
-- Returns the item count. Positions become 1…n in array order.
create or replace function public.reorder_list(p_list_id uuid, p_item_ids uuid[])
returns int language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_list  public.user_lists := public.list_own(p_list_id);
  v_count int;
  v_given int := coalesce(cardinality(p_item_ids), 0);
begin
  select count(*) into v_count from public.user_list_items where list_id = v_list.id;
  if p_item_ids is null
     or v_given <> v_count
     or (select count(distinct x) from unnest(p_item_ids) x) <> v_given
     or exists (select 1 from unnest(p_item_ids) x
                where x is null
                   or not exists (select 1 from public.user_list_items i where i.id = x and i.list_id = v_list.id)) then
    raise exception 'reorder_mismatch' using errcode = '22023';
  end if;
  update public.user_list_items i set position = o.ord::int
  from unnest(p_item_ids) with ordinality as o(id, ord)
  where i.id = o.id and i.list_id = v_list.id;
  update public.user_lists set updated_at = now() where id = v_list.id;
  return v_count;
end; $$;

-- ===========================================================================
-- 6. List reads (INVOKER: RLS already scopes them to the caller; the filters say so explicitly too).
-- ===========================================================================
-- My lists, newest first; keyset (created_at, id) — both from the last row, or neither. `covers` = up to 4
-- distinct item photos in list order (`[]` when none).
create or replace function public.my_lists(
  p_limit             int         default 50,
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null
)
returns table (list_id uuid, name text, visibility text, item_count int, covers text[],
               created_at timestamptz, updated_at timestamptz)
language plpgsql stable security invoker set search_path = public, extensions as $$
#variable_conflict use_column
begin
  if (p_cursor_created_at is null) <> (p_cursor_id is null) then
    raise exception 'p_cursor_created_at and p_cursor_id go together' using errcode = '22023';
  end if;
  return query
  select l.id, l.name, l.visibility,
         (select count(*)::int from public.user_list_items i where i.list_id = l.id),
         coalesce((select array_agg(u.url order by u.first_pos)
                   from (select ph.url, min(ph.pos) first_pos
                         from (select public.list_item_photo(i.entry_id, i.dish_id) url, i.position pos
                               from public.user_list_items i where i.list_id = l.id) ph
                         where ph.url is not null
                         group by ph.url order by min(ph.pos) limit 4) u), '{}'::text[]),
         l.created_at, l.updated_at
  from public.user_lists l
  where l.owner_id = (select auth.uid())
    and (p_cursor_created_at is null or (l.created_at, l.id) < (p_cursor_created_at, p_cursor_id))
  order by l.created_at desc, l.id desc
  limit least(greatest(coalesce(p_limit, 50), 1), 50);
end; $$;

-- One list with its items, in order. Not yours / gone → P0002.
create or replace function public.get_list(p_list_id uuid)
returns jsonb language plpgsql stable security invoker set search_path = public, extensions as $$
declare
  v_list public.user_lists;
begin
  select * into v_list from public.user_lists where id = p_list_id and owner_id = (select auth.uid());
  if not found then
    raise exception 'list_not_found' using errcode = 'P0002';
  end if;
  return jsonb_build_object(
    'list_id', v_list.id, 'name', v_list.name, 'visibility', v_list.visibility,
    'created_at', v_list.created_at, 'updated_at', v_list.updated_at,
    'item_count', (select count(*) from public.user_list_items i where i.list_id = v_list.id),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'item_id', i.id, 'position', i.position, 'entry_id', i.entry_id, 'dish_id', i.dish_id,
               'dish_name', d.name, 'restaurant_id', p.id, 'restaurant_name', p.name,
               'locality', public.place_locality(p.address, p.city),
               'score', public.list_item_score(i.entry_id, i.dish_id),
               'photo_url', public.list_item_photo(i.entry_id, i.dish_id),
               'visited_at', e.created_at, 'added_at', i.added_at)
             order by i.position, i.id)
      from public.user_list_items i
      join public.entries e     on e.id = i.entry_id
      join public.dishes d      on d.id = i.dish_id
      join public.restaurants p on p.id = d.restaurant_id
      where i.list_id = v_list.id), '[]'::jsonb));
end; $$;

-- The add-to-list sheet: EVERY list of mine (my_lists' order, ≤ 50, unpaged) and whether it holds this
-- dish line (`item_id` non-null = it does; pass it to remove_list_item to untick).
create or replace function public.my_lists_for_dish_line(p_entry_id uuid, p_dish_id uuid)
returns table (list_id uuid, name text, item_count int, item_id uuid)
language sql stable security invoker set search_path = public, extensions as $$
  select l.id, l.name,
         (select count(*)::int from public.user_list_items i where i.list_id = l.id),
         (select i.id from public.user_list_items i
          where i.list_id = l.id and i.entry_id = p_entry_id and i.dish_id = p_dish_id)
  from public.user_lists l
  where l.owner_id = (select auth.uid())
  order by l.created_at desc, l.id desc;
$$;

-- The picker: my dish lines, one row per (visit, dish), newest visit first. p_query (trimmed, under 2
-- characters = no filter) matches the dish OR place name, accent-insensitive substring (search_key).
-- p_scored_only (default true) keeps lines with a score. p_list_id (optional) fills `in_list`.
-- Keyset (visited_at, entry_id, dish_id) DESC — all three from the last row, or none.
create or replace function public.my_scored_dishes(
  p_query              text        default null,
  p_scored_only        boolean     default true,
  p_list_id            uuid        default null,
  p_limit              int         default 30,
  p_cursor_visited_at  timestamptz default null,
  p_cursor_entry_id    uuid        default null,
  p_cursor_dish_id     uuid        default null
)
returns table (entry_id uuid, dish_id uuid, dish_name text, restaurant_id uuid, restaurant_name text,
               locality text, score numeric, photo_url text, visited_at timestamptz, in_list boolean)
language plpgsql stable security invoker set search_path = public, extensions as $$
#variable_conflict use_column
declare
  v_uid uuid := (select auth.uid());
  v_pat text := case when char_length(public.search_key(p_query)) >= 2 then public.search_pattern(p_query) end;
begin
  if not ((p_cursor_visited_at is null and p_cursor_entry_id is null and p_cursor_dish_id is null)
       or (p_cursor_visited_at is not null and p_cursor_entry_id is not null and p_cursor_dish_id is not null)) then
    raise exception 'the three cursor fields go together' using errcode = '22023';
  end if;
  return query
  with lines as (
    select distinct on (e.created_at, e.id, r.dish_id)
           e.id eid, r.dish_id did, e.created_at as visited, r.score
    from public.entries e
    join public.reviews r on r.entry_id = e.id
    where e.author_id = v_uid
      and (not coalesce(p_scored_only, true) or r.score is not null)
      and (p_cursor_visited_at is null
           or (e.created_at, e.id, r.dish_id) < (p_cursor_visited_at, p_cursor_entry_id, p_cursor_dish_id))
    order by e.created_at desc, e.id desc, r.dish_id desc, r.entry_position nulls last, r.id
  )
  select ln.eid, ln.did, d.name, p.id, p.name, public.place_locality(p.address, p.city), ln.score,
         public.list_item_photo(ln.eid, ln.did), ln.visited,
         case when p_list_id is null then false
              else exists (select 1 from public.user_list_items i
                           where i.list_id = p_list_id and i.entry_id = ln.eid and i.dish_id = ln.did) end
  from lines ln
  join public.dishes d      on d.id = ln.did
  join public.restaurants p on p.id = d.restaurant_id
  where v_pat is null
     or public.search_key(d.name) like '%' || v_pat || '%'
     or public.search_key(p.name) like '%' || v_pat || '%'
  order by ln.visited desc, ln.eid desc, ln.did desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
end; $$;

-- ===========================================================================
-- 7. Journal search.
-- ===========================================================================
-- Your OWN entries whose words, place name or any line's dish name contain the query (search_key: trimmed,
-- accent-folded, lower; LIKE metacharacters literal). Under 2 characters → []. The Journal's order and
-- keyset: (created_at, id) DESC, both from the last row or neither. Rows are entry_cards.
create or replace function public.search_my_entries(
  p_query             text,
  p_limit             int         default 20,
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null
)
returns setof public.entry_cards
language plpgsql stable security invoker set search_path = public, extensions as $$
#variable_conflict use_column
declare
  v_uid uuid := (select auth.uid());
  v_pat text;
begin
  if v_uid is null then
    raise exception 'sign in to search your journal' using errcode = '42501';
  end if;
  if (p_cursor_created_at is null) <> (p_cursor_id is null) then
    raise exception 'p_cursor_created_at and p_cursor_id go together' using errcode = '22023';
  end if;
  if char_length(public.search_key(p_query)) < 2 then
    return;
  end if;
  v_pat := '%' || public.search_pattern(p_query) || '%';
  return query
  select c.*
  from public.entry_cards c
  where c.id in (
    select e.id
    from public.entries e
    left join public.restaurants p on p.id = e.restaurant_id
    where e.author_id = v_uid
      and (p_cursor_created_at is null or (e.created_at, e.id) < (p_cursor_created_at, p_cursor_id))
      and (public.search_key(e.body) like v_pat
           or public.search_key(p.name) like v_pat
           or exists (select 1 from public.reviews r join public.dishes d on d.id = r.dish_id
                      where r.entry_id = e.id and public.search_key(d.name) like v_pat))
    order by e.created_at desc, e.id desc
    limit least(greatest(coalesce(p_limit, 20), 1), 50))
  order by c.created_at desc, c.id desc;
end; $$;

-- ===========================================================================
-- 8. delete_account — 0058's body verbatim, plus the two list tables in the "nothing survived" check.
-- ===========================================================================
create or replace function public.delete_account()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_deleted int;
begin
  if v_uid is null then
    raise exception 'delete_account requires an authenticated caller' using errcode = '42501';
  end if;

  delete from auth.users where id = v_uid;
  get diagnostics v_deleted = row_count;
  if v_deleted <> 1 then
    raise exception 'delete_account: no auth user % to delete', v_uid using errcode = 'P0002';
  end if;

  if exists (select 1 from public.profiles       where id = v_uid)
  or exists (select 1 from public.entries        where author_id = v_uid)
  or exists (select 1 from public.reviews        where reviewer_id = v_uid)
  or exists (select 1 from public.saves          where user_id = v_uid)
  or exists (select 1 from public.blocks         where blocker_id = v_uid or blocked_id = v_uid)
  or exists (select 1 from public.reports        where reporter_id = v_uid or profile_id = v_uid)
  or exists (select 1 from public.comments       where user_id = v_uid)
  or exists (select 1 from public.lists          where owner_id = v_uid)
  or exists (select 1 from public.follows        where follower_id = v_uid or followee_id = v_uid)
  or exists (select 1 from public.review_likes   where user_id = v_uid)
  or exists (select 1 from public.comment_likes  where user_id = v_uid)
  or exists (select 1 from public.review_tags    where tagged_user_id = v_uid or tagger_id = v_uid)
  or exists (select 1 from public.notifications  where recipient_id = v_uid or actor_id = v_uid)
  or exists (select 1 from public.sort_preview_cache where author_id = v_uid)
  or exists (select 1 from public.sort_preview_rate  where author_id = v_uid)
  or exists (select 1 from public.user_cravings  where user_id = v_uid)
  or exists (select 1 from public.entry_companions   where tagger_id = v_uid or companion_id = v_uid)
  or exists (select 1 from public.entry_invites      where inviter_id = v_uid or redeemed_by = v_uid)
  or exists (select 1 from public.device_push_tokens where user_id = v_uid)
  or exists (select 1 from public.ate_with_ledger    where actor_id = v_uid or recipient_id = v_uid)
  or exists (select 1 from public.user_lists         where owner_id = v_uid)
  or exists (select 1 from public.user_list_items    where owner_id = v_uid)
  then
    raise exception 'delete_account: personal rows survived the cascade for %', v_uid
      using errcode = 'P0001';
  end if;

  return jsonb_build_object('ok', true, 'auth_user_deleted', true);
end; $$;

-- ===========================================================================
-- 9. Grants. Every RPC is signed-in only; anon gets nothing new.
-- ===========================================================================
revoke all on function public.create_list(text)                                  from public, anon;
revoke all on function public.rename_list(uuid, text)                            from public, anon;
revoke all on function public.delete_list(uuid)                                  from public, anon;
revoke all on function public.add_list_item(uuid, uuid, uuid)                    from public, anon;
revoke all on function public.remove_list_item(uuid)                             from public, anon;
revoke all on function public.reorder_list(uuid, uuid[])                         from public, anon;
revoke all on function public.my_lists(int, timestamptz, uuid)                   from public, anon;
revoke all on function public.get_list(uuid)                                     from public, anon;
revoke all on function public.my_lists_for_dish_line(uuid, uuid)                 from public, anon;
revoke all on function public.my_scored_dishes(text, boolean, uuid, int, timestamptz, uuid, uuid) from public, anon;
revoke all on function public.search_my_entries(text, int, timestamptz, uuid)    from public, anon;
revoke all on function public.delete_account()                                   from public, anon;
grant execute on function public.create_list(text)                               to authenticated, service_role;
grant execute on function public.rename_list(uuid, text)                         to authenticated, service_role;
grant execute on function public.delete_list(uuid)                               to authenticated, service_role;
grant execute on function public.add_list_item(uuid, uuid, uuid)                 to authenticated, service_role;
grant execute on function public.remove_list_item(uuid)                          to authenticated, service_role;
grant execute on function public.reorder_list(uuid, uuid[])                      to authenticated, service_role;
grant execute on function public.my_lists(int, timestamptz, uuid)                to authenticated, service_role;
grant execute on function public.get_list(uuid)                                  to authenticated, service_role;
grant execute on function public.my_lists_for_dish_line(uuid, uuid)              to authenticated, service_role;
grant execute on function public.my_scored_dishes(text, boolean, uuid, int, timestamptz, uuid, uuid) to authenticated, service_role;
grant execute on function public.search_my_entries(text, int, timestamptz, uuid) to authenticated, service_role;
grant execute on function public.delete_account()                                to authenticated;
