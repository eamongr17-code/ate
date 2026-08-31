# Ate — product brief (ratified 2026-08-31)

**The dish is the atom.** Every food platform rates restaurants; nobody eats a restaurant. The real
decision happens menu-in-hand: **"what should I order here?"** Ate's long-term answer: stand in any
restaurant in Melbourne, open Ate, see its menu ranked by people who actually ate it.

That needs dish density, and density is earned. The flywheel, in order:
**a sub-30-second log people enjoy → every log feeds the global feed + the logger's diary →
shared receipts pull new loggers in → per-restaurant dish density accumulates → the ranked-menu
answer switches on and becomes the reason everyone else installs.**

## For
Food-curious Melburnians in their 20s–30s, starting with Eamon's circle. iPhone, by strategy.
**Density beats breadth**: 50 active loggers in Melbourne > 5,000 spread thin. One city until won.

## V1 — the logging product (current)
Five surfaces, nothing else:
1. **Feed** (home) — one global stream of every dish review. No follow graph.
2. **Log** — pick restaurant/dish → rate (half-star gesture, multi-dish sittings) → posted receipt.
3. **Dish / Restaurant detail**
4. **Diary** on profile — your own history.
5. **Search** — find to log, find to recall.

Explicitly OUT of V1: follows, comments, notifications, lists, companion tagging. The schema keeps
all of it; the product doesn't show it. Social is sequenced *behind* density, never ahead of it.

## V2 — the answer product (gated)
"What should I order here?" — the ranked menu as the restaurant page, location-aware.
**Tripwire**: build V2 when ~40% of restaurant pages viewed can answer the question (≥3 rated
dishes). Checked against real data, not vibes.

## V3 — the network product (later)
Follows, comments, notifications, taste-matching, city #2, Android.

## Metrics
- **North star: dishes logged per weekly active user.**
- Log friction: median seconds from `+` to posted (target <30 at a repeat restaurant).
- Growth loop: share rate per log; receipt-attributed installs.
- Density tripwire (above).
- **Anti-metrics** (never optimize, never celebrate): registered users, time-in-feed.

The strategy is falsified if people install, browse, and don't log — in which case we rebuild the
log flow, not the feature set.

## Principles that decide arguments
1. The dish is the atom — the dish-centric option wins ties.
2. Borrow Apple's UI; spend custom taste only on the rating gesture, dish card, and receipt.
3. Thirty seconds, one hand, mid-meal — every log-flow field is paid for in lost logs.
4. Good with one user in one city — no feature may depend on scale to be worth using.
5. The share is the marketing — every log ends in an artifact worth posting.
6. Brand is a coating — built on neutral native chrome + Theme seam until Eamon defines it.

Full strategy: https://claude.ai/code/artifact/30590f91-f8b3-41f1-ac83-15d234a6f7b2
