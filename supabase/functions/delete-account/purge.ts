// supabase/functions/delete-account/purge.ts
//
// Empties a deleted account's storage folders: review-photos/<uid>/ (entry photos, and list covers one
// level down in list-covers/) and avatars/<uid>/. Pure: the storage calls are injected, so Node runs
// the suite. Bounded, so a folder that somehow never shrinks cannot hold a request open forever.

export const PERSONAL_BUCKETS = ['review-photos', 'avatars'] as const;

/** The two storage calls the purge makes (the supabase-js bucket API's shape). */
export type Bucket = {
  list(path: string, opts: { limit: number }): Promise<{ data: { name: string; id: string | null }[] | null; error: unknown }>;
  remove(paths: string[]): Promise<{ data: unknown[] | null; error: unknown }>;
};

const PAGE = 100;
const MAX_PAGES = 50;
const MAX_DEPTH = 2;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Removes every file under `folder` (and its sub-folders). Returns how many were removed; throws on a storage error. */
export async function purgeFolder(bucket: Bucket, folder: string, depth = 0): Promise<number> {
  let removed = 0;
  const subfolders = new Set<string>();
  for (let page = 0; page < MAX_PAGES; page++) {
    const listed = await bucket.list(folder, { limit: PAGE });
    if (listed.error) throw new Error(`list ${folder}: ${String((listed.error as { message?: string }).message ?? listed.error)}`);
    const rows = listed.data ?? [];
    // a listed row with no id is a folder, not a file
    for (const r of rows) if (r.id == null) subfolders.add(`${folder}/${r.name}`);
    const files = rows.filter((r) => r.id != null).map((r) => `${folder}/${r.name}`);
    if (!files.length) break;
    const gone = await bucket.remove(files);
    if (gone.error) throw new Error(`remove ${folder}: ${String((gone.error as { message?: string }).message ?? gone.error)}`);
    if (!gone.data?.length) break;
    removed += gone.data.length;
  }
  if (depth < MAX_DEPTH) {
    for (const sub of [...subfolders].sort()) removed += await purgeFolder(bucket, sub, depth + 1);
  }
  return removed;
}

/** Every personal bucket's folder for one account. Only ever a uuid: nothing outside `<uid>/` is touched. */
export async function purgeAccount(bucketFor: (name: string) => Bucket, userId: string): Promise<number> {
  if (!UUID.test(userId)) throw new Error('not a user id');
  let removed = 0;
  for (const name of PERSONAL_BUCKETS) removed += await purgeFolder(bucketFor(name), userId.toLowerCase());
  return removed;
}

/**
 * The same account's folders on Cloudflare R2 (0101), through the photos Worker at `photoBase`
 * (photo_storage.base), which empties `review-photos/<uid>/` and `avatars/<uid>/`. The service key is
 * the Worker's proof that the call comes from us. No base = photos never left Supabase: nothing to do.
 * Throws on anything but a 200, so the account stays queued and is retried.
 */
export async function purgeR2(
  photoBase: string | null,
  serviceKey: string,
  userId: string,
  fetchImpl: typeof fetch = fetch,
): Promise<number> {
  if (!photoBase) return 0;
  if (!UUID.test(userId)) throw new Error('not a user id');
  const res = await fetchImpl(`${photoBase.replace(/\/+$/, '')}/v1/purge`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${serviceKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ user_id: userId.toLowerCase() }),
  });
  if (!res.ok) throw new Error(`R2 purge: HTTP ${res.status}`);
  const body = (await res.json().catch(() => ({}))) as { removed?: unknown };
  return typeof body.removed === 'number' ? body.removed : 0;
}
