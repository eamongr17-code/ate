// supabase/functions/send-push/index.ts
//
// Ate — PUSH for "ate with" (0058/0059). Woken by the database (pg_net, from push_kick: on a tag of a
// sorted entry, on an entry finishing its sort with pending tags, and every minute by pg_cron while
// anything is ready). It drains: claims ready notifications, sends each to the recipient's devices
// over APNs, marks them pushed, drops dead tokens.
//
//   POST /functions/v1/send-push      Authorization: Bearer <service role key>      body: ignored
//   → 200 { ok, claimed, sent, marked, dropped }
//     200 { ok: true, skipped: 'apns_not_configured' }   (any APNS_* secret absent — a harmless no-op)
//     401 unauthorized (anything but the service role) · 500 claim failed
//
// WHAT IS SENT is decided in SQL (push_claim_ate_with, 0059): pending tag, unread, undismissed, unpushed
// (so never a quiet re-tag), no block, the tagger's entry sorted. This file never widens that set.
//
// APNs: HTTP/2 (Deno's fetch negotiates h2 by ALPN) with token auth — an ES256 JWT from the .p8 key,
// cached under 50 minutes. Secrets: APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY (the .p8's PEM text),
// APNS_ENV = sandbox | production (picks the host; only tokens registered with the same apns_env are
// sent to). Topic com.eamongracias.ate. Payload: push.ts `payload()`; contract in integration-design.md.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { createHandler, type Db } from './push.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

Deno.serve(createHandler({
  env: (name) => Deno.env.get(name),
  db: () => createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } }) as unknown as Db,
  fetch: (url, init) => fetch(url, init),
}));
