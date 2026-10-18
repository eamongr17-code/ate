// supabase/functions/dish-dedup/scan_test.ts
//
//   node --test supabase/functions/dish-dedup/scan_test.ts
//
// The scan of existing dishes only proposes, and proposes narrowly: the spelling tier, the fence in
// front of the model, the model's answer read strictly, and the survivor rule.

import { test, assert, assertEquals } from '../sort-entry/harness.ts';
import { aiProposals, buildRequest, candidatePairs, judgePlace, sameNameProposals, scanPlace, survivor, type ScanDish, type ScanPlace } from './scan.ts';

let n = 0;
const dish = (name: string, lines = 1, created_at = `2026-10-0${(n % 9) + 1}T00:00:00Z`): ScanDish =>
  ({ id: `d${String(++n).padStart(3, '0')}`, name, lines, created_at, notes: [] });
const place = (dishes: ScanDish[], shared: [string, string][] = []): ScanPlace =>
  ({ restaurant_id: 'r1', place_name: 'Tipo 00', dishes, shared_pairs: shared });
const reply = (verdicts: unknown, stop_reason = 'tool_use') =>
  ({ stop_reason, content: [{ type: 'tool_use', name: 'judge_pairs', input: { verdicts } }] });

test('survivor: more lines, then the older dish', () => {
  const a = dish('Carbonara', 3, '2026-10-05T00:00:00Z');
  const b = dish('Spaghetti Carbonara', 1, '2026-10-01T00:00:00Z');
  assertEquals(survivor(a, b)[0].id, a.id);
  assertEquals(survivor(b, { ...a, lines: 1 })[0].id, b.id, 'a tie goes to the older');
});

test('same spelling key folds into its survivor; one entry naming both keeps them apart', () => {
  const g1 = dish('Gnocchi', 4);
  const g2 = dish('Gnocchis', 1);
  const t1 = dish('Taco', 1);
  const t2 = dish('Tacos', 1);
  const r = sameNameProposals(place([g1, g2, t1, t2, dish('Tiramisu')], [[t1.id, t2.id]]));
  assertEquals(r.proposals.map((p) => [p.source_name, p.target_name, p.reason]), [['Gnocchis', 'Gnocchi', 'same_name']]);
  assertEquals(r.rest.length, 4, 'gnocchi once, both tacos, the tiramisu');
});

test('only pairs the fence allows go to the model', () => {
  const dishes = [
    dish('Spaghetti Carbonara'), dish('Carbonara'),
    dish('Beef Ragu Pappardelle'), dish('Pork Ragu Gnocchi'), dish('Ragu'),
    dish('Scotch Fillet Steak'), dish('Steak'), dish('Ribeye'),
  ];
  const pairs = candidatePairs(place(dishes), dishes).map((p) => [p.a.name, p.b.name].sort().join(' / '));
  assertEquals(pairs, ['Carbonara / Spaghetti Carbonara'], 'two ragus: a guess; steak: a category; ribeye: another cut');
});

test('a pair one entry names is never asked about', () => {
  const a = dish('Spaghetti Carbonara');
  const b = dish('Carbonara');
  assertEquals(candidatePairs(place([a, b], [[b.id, a.id]]), [a, b]), []);
});

test('the request: every dish with notes, numbered pairs, no forced tool, explicit effort, fallback on', () => {
  const a = { ...dish('Spaghetti Carbonara'), notes: ['silky, lots of pepper'] };
  const b = dish('Carbonara');
  const req = buildRequest({ apiKey: 'k', place: place([a, b]), pairs: [{ a, b }] });
  const body = JSON.parse(req.body);
  assertEquals(body.model, 'claude-opus-5-5');
  assertEquals(body.tool_choice, { type: 'auto' });
  assertEquals(body.output_config, { effort: 'high' });
  assertEquals(body.fallbacks, 'default');
  assert(req.headers['anthropic-beta'].includes('server-side-fallback'));
  assert(!('thinking' in body) && !('temperature' in body));
  assert(body.messages[0].content.includes('silky, lots of pepper'));
  assert(body.messages[0].content.includes('1. "Spaghetti Carbonara" / "Carbonara"'));
});

test('the answer: only "same" proposes; unsure, different, bad numbers, a refusal propose nothing', () => {
  const a = dish('Spaghetti Carbonara', 2);
  const b = dish('Carbonara', 1);
  const c = dish('Pappardelle');
  const d = dish('Pappardelle Ragu');
  const p = place([a, b, c, d]);
  const pairs = [{ a, b }, { a: c, b: d }];
  const out = aiProposals(reply([
    { pair: 1, verdict: 'same', why: 'the one carbonara' },
    { pair: 2, verdict: 'unsure', why: 'may be two' },
    { pair: 7, verdict: 'same', why: 'no such pair' },
  ]), p, pairs)!;
  assertEquals(out.map((x) => [x.source_name, x.target_name, x.why]), [['Carbonara', 'Spaghetti Carbonara', 'the one carbonara']]);
  assertEquals(aiProposals(reply([{ pair: 1, verdict: 'same' }], 'refusal'), p, pairs), null);
  assertEquals(aiProposals({ content: [{ type: 'text', text: 'same' }] }, p, pairs), null);
});

test('a dish proposed into two survivors, or a chain, is a guess: none of it', () => {
  const a = dish('Margherita Pizza', 3);
  const b = dish('Margherita', 1);
  const c = dish('Margherita Special', 2);
  const out = aiProposals(reply([{ pair: 1, verdict: 'same', why: '' }, { pair: 2, verdict: 'same', why: '' }]),
    place([a, b, c]), [{ a, b }, { a: c, b }]);
  assertEquals(out, []);
});

test('no key, or a failed call: the spelling tier still proposes, the model tier proposes nothing', async () => {
  const dishes = [dish('Spaghetti Carbonara', 2), dish('Carbonara'), dish('Gnocchi', 2), dish('Gnocchis')];
  const noKey = await scanPlace(place(dishes), { apiKey: '' });
  assertEquals(noKey.proposals.map((x) => x.reason), ['same_name']);
  assert(noKey.failed);
  const broken = await scanPlace(place(dishes), {
    apiKey: 'k', fetchImpl: async () => new Response('overloaded', { status: 529 }),
  });
  assertEquals(broken.proposals.map((x) => x.reason), ['same_name']);
  assertEquals(await judgePlace({ apiKey: 'k', place: place(dishes), pairs: [] }), []);
  const ok = await scanPlace(place(dishes), {
    apiKey: 'k', fetchImpl: async () => Response.json(reply([{ pair: 1, verdict: 'same', why: 'one dish' }])),
  });
  assertEquals(ok.proposals.map((x) => [x.reason, x.source_name]), [['same_name', 'Gnocchis'], ['ai', 'Carbonara']]);
});
