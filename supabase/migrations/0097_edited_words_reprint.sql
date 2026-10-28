-- 0097_edited_words_reprint.sql
-- Ate backend — an entry whose words change is printing again, and never keeps a score its words
-- no longer say (weekly audit 28 Oct; Eamon said yes).
--
-- Before: the app PATCHed entries.body and asked for a forced re-sort afterwards, fire-and-forget.
-- When that re-sort failed (network drop after the PATCH, sorter 500, app closed) nothing retried
-- it, and the entry kept printing its old lines and scores under the new words — a score with no
-- words behind it, which rule 7 forbids.
--
-- Now, when the author changes the words:
--   * the entry goes back to `pending`: the app already watches a pending entry, offers "Try again"
--     past the watch, and the sort that follows sets `sorted` as for a new entry;
--   * each line the author did NOT correct by hand loses a score whose evidence is no longer in the
--     words (the same rule apply_entry_sort applies on every sort);
--   * offsets are left as they were: the re-sort re-places every line, and it carries a marked 6 by
--     the distance between the old mention and evidence offsets, which must stay a pair. The client
--     already bounds-checks an offset past the end of the words.
-- A line the author corrected keeps its score: that score is theirs, not the words'.
--
-- Only client writes (anon/authenticated) count: definer RPCs and the sorter write as other roles.
-- Volume: one indexed UPDATE on the entry's own lines (reviews by entry_id), only when the words differ.

set search_path = public, extensions;

-- 0024's correction net, with one more explicit exception beside `ate.repointing`: a score dropped
-- here because its words are gone is the words' doing, not a per-line decision by the author, so it
-- must not stamp corrected_at (a stamped line would keep the dropped score out of every re-sort).
-- Otherwise verbatim.
create or replace function public.trg_review_mark_corrected()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid       uuid := (select auth.uid());
  v_repointing boolean := coalesce(current_setting('ate.repointing', true) = 'on', false);
  v_rewording  boolean := coalesce(current_setting('ate.rewording', true) = 'on', false);
  v_changed   boolean;
begin
  -- never lose an existing stamp
  new.corrected_at := coalesce(new.corrected_at, old.corrected_at);

  if v_uid is null or v_uid <> new.reviewer_id or v_rewording then
    return new;                       -- the sorter / service role / 0097: not a correction
  end if;
  if new.corrected_at is distinct from old.corrected_at then
    return new;                       -- an explicit setter (correct_entry_dish) wins
  end if;

  v_changed := (new.score is distinct from old.score)
            or (new.note  is distinct from old.note)
            or (not v_repointing and new.dish_id is distinct from old.dish_id);

  if v_changed then
    new.corrected_at := now();
    if new.dish_id is distinct from old.dish_id and new.corrected_from_name is null and not v_repointing then
      select d.name into new.corrected_from_name from public.dishes d where d.id = old.dish_id;
    end if;
  end if;
  return new;
end; $$;

revoke execute on function public.trg_review_mark_corrected() from public, anon, authenticated;

-- The lines' half. Definer (clients cannot write reviews), so it checks the caller owns the entry.
create or replace function public.entry_words_changed(p_entry_id uuid, p_body text)
returns void language plpgsql volatile security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from public.entries e where e.id = p_entry_id and e.author_id = (select auth.uid())) then
    return;
  end if;
  perform set_config('ate.rewording', 'on', true);
  update public.reviews r
     set score = null, score_evidence = null, evidence_offset = null
   where r.entry_id = p_entry_id
     and r.corrected_at is null and r.score_evidence is not null
     and position(r.score_evidence in p_body) = 0;
  perform set_config('ate.rewording', 'off', true);
end; $$;

revoke all on function public.entry_words_changed(uuid, text) from public, anon, authenticated;
grant execute on function public.entry_words_changed(uuid, text) to authenticated;

-- Invoker, so current_user still says who is writing.
create or replace function public.trg_entry_words_changed()
returns trigger language plpgsql security invoker set search_path = public, extensions as $$
begin
  if current_user not in ('anon', 'authenticated') then return new; end if;
  if new.body is not distinct from old.body then return new; end if;
  new.sort_status := 'pending';
  perform public.entry_words_changed(new.id, new.body);
  return new;
end; $$;

revoke execute on function public.trg_entry_words_changed() from public, anon, authenticated;

drop trigger if exists entries_words_changed on public.entries;
create trigger entries_words_changed
  before update of body on public.entries
  for each row execute function public.trg_entry_words_changed();
