-- 0105: drop the 0104 fold backups. Eamon checked the merged same-day entries in prod on
-- 3 Nov 2026 and OK'd deleting them. Nothing reads these tables; the fold itself stays.
drop table if exists
  public.backup_0104_entries,
  public.backup_0104_reviews,
  public.backup_0104_entry_photos,
  public.backup_0104_photo_dishes,
  public.backup_0104_entry_companions,
  public.backup_0104_user_list_items,
  public.backup_0104_six_grants,
  public.backup_0104_saves,
  public.backup_0104_user_awards;
