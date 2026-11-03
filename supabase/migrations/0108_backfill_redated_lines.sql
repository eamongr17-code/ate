-- 0108_backfill_redated_lines.sql
-- Ate backend: the one-off half of 0107 (Eamon said yes, 3 Nov). Before 0107, set_entry_date moved
-- an entry to the day you ate it but left its dish lines on the day it was typed. 0107 moves them
-- from now on. This puts the lines already out of step on their entry's time (prod: 8 lines on 6
-- entries when this was written).
--
-- Runs as the migration role, so the correction net (0024/0097) and the awards triggers (score and
-- dish only) do not fire: no line is marked corrected. Volume: one pass over reviews joined to
-- entries by primary key; idempotent.

update public.reviews r
   set created_at = e.created_at
  from public.entries e
 where e.id = r.entry_id
   and r.created_at is distinct from e.created_at;
