# Dijkstra Multimodal Transit Router — Design

**Date:** 2026-07-22
**Status:** Approved, ready for implementation
**Requirement:** R6 (commute guide), Specific Objective 3

## Problem

The capstone specifies route computation "using Dijkstra's algorithm" over GTFS
data. The shipped implementation is a **direct-route matcher**: a linear scan
that finds routes whose stops are near both origin and destination. It has no
graph, no priority queue, and **cannot plan a transfer**.

That contradicts the paper's own premise. Narboneta and Teknomo (2016), cited in
Chapter 2, found Metro Manila commuters use an average of **three modes per
trip** — exactly the multi-hop case the current code cannot serve.

## Measured data shape

Profiled from `assets/gtfs/routes.json.gz` rather than assumed:

| Metric | Value |
|---|---|
| Routes | 1,711 (1,522 jeepney, 189 bus) |
| Stop-points | 74,018 |
| **Unique coordinates** | **4,781** (15.5× dedup) |
| Ride edges | 72,307 |
| Walk edges ≤250 m | ~10,076 |

Two consequences:

1. The search space is far smaller than the raw 74,018 suggests. The dedup is
   also what makes transfers *possible* — identical corners on different routes
   would otherwise never connect.
2. **There is no UV Express data in the feed**, though R6 and Figure 21 promise
   it. Decision: route on real jeepney/bus data; UV Express keeps its synthetic
   estimate, clearly labelled. Never invent a UV route that does not exist.

## Out of scope

Trains. Scope and Limitations states the app "will not cover trains, tricycles,
or motorcycles," and no rail exists in the feed. A Jeepney→LRT transfer cannot
be built without contradicting the paper.

## Graph model

A stop-only graph **cannot compute fares correctly**: jeepney fare is ₱13 for
the first 4 km *of each boarding*, so cost depends on where the rider boarded
and whether they stayed aboard. Nodes therefore carry route identity.

Two node kinds:

- **Ride node** `(stop, route)` — "aboard route R at stop S". 74,018 of them.
- **Hub node** `(stop)` — "standing at stop S, not aboard". 4,781 of them.

Total **78,799 nodes**. Four edge kinds:

| Edge | From → To | Time weight | Fare weight |
|---|---|---|---|
| Ride | (S₁,R) → (S₂,R) | km / modeSpeed × 60 | perKm × km (proxy) |
| Alight | (S,R) → hub(S) | 0 | 0 |
| Board | hub(S) → (S,R) | transferPenalty + boardingWait | base fare |
| Walk | hub(S₁) → hub(S₂) ≤250 m | km / 4.5 kph × 60 | 0 |

The hub node is what keeps this tractable. Connecting `(S,R₁) → (S,R₂)`
directly is O(k²) per stop — at ~15.5 routes per stop that is ~1.15M edges, and
far worse at hubs. Routing through a hub is O(k), giving **~230K edges total**.

**Transfer penalty: 5 min**, on top of the existing 7 min `boardingWaitMin`.
Jeon et al. (2018), cited in Chapter 2, found that routers ignoring transfer
penalties return paths real passengers reject. A 3-transfer route is therefore
penalised ~36 min against a 1-transfer alternative.

## Transfer cap

Search state is `(node, boardingsSoFar)`, capped at **4 boardings = 3
transfers**, matching the paper's three-modes finding. Encoding the count in the
state (rather than pruning) keeps Dijkstra provably optimal within the cap.

State space: 78,799 × 5 = 393,995. At `Float32List` that is ~1.6 MB per pass.

## Fare: approximate to search, exact to display

Fare is state-dependent and cannot be an exact edge weight.

- **During search (fare pass):** proxy = base fare on each board edge + per-km
  on ride edges. Monotonic and non-negative, so Dijkstra remains valid. A small
  time term (0.05 × minutes) is added to break ties, otherwise a fare-optimal
  search returns absurd walk-forever paths.
- **After search:** group contiguous same-route legs on the returned path and
  apply the **exact LTFRB matrix** already unit-tested in `RouteEngine`
  (₱13/4 km + ₱1.80/km; ₱15/5 km + ₱2.65/km).

The displayed fare is therefore always exact. The proxy can occasionally select
a marginally sub-optimal *path*; this is stated rather than papered over.

## Two passes

Figure 22 requires genuinely differently-ranked Fastest and Cheapest options.
Pass 1 minimises time; pass 2 minimises the fare proxy. Identical paths are
deduplicated. Two passes over this graph remain in the tens of milliseconds.

## Isolate and memory

A **long-lived worker isolate**, spawned lazily on first search.

- Decompresses the asset once and builds adjacency as **flat CSR typed arrays**
  (`Int32List` offsets and targets, `Float32List` weights). Not `List<Object>`,
  which would box ~230K edges and balloon the heap.
- Estimated resident ~3–5 MB, held **off the UI heap** entirely.
- The UI sends `(originLat, originLng, destLat, destLng, prefs)` over a port and
  receives ranked paths. Only small messages cross; the graph is never copied.
- Disposed after **5 minutes idle** to return memory.

This addresses the OOM concern directly: the failure modes are rebuilding per
request and boxing edges as objects, and both are designed out. Target hardware
is 4 GB RAM (Table 30).

Origin and destination attach as virtual nodes joined to every hub within
**800 m**, matching the existing `maxWalkM`.

## Components

| File | Responsibility |
|---|---|
| `lib/services/transit_graph.dart` | Build CSR arrays from decoded GTFS. Pure, no I/O. |
| `lib/services/transit_router.dart` | Dijkstra over CSR + path reconstruction. Pure. |
| `lib/services/routing_isolate.dart` | Long-lived isolate, lifecycle, port protocol. |
| `lib/services/gtfs_service.dart` | `planRoutes()` replaces `directRoutes()`. |
| `lib/services/route_engine.dart` | Exact LTFRB fare on returned paths (unchanged API). |

`RouteEngine.buildFromGtfs()` keeps its signature, so `GuideLeg` coordinates,
the live commute guide sheet, and Figure 22 tagging all continue to work
untouched.

## Fallback chain

Dijkstra → synthetic estimate → NCR out-of-area message. Unchanged in behaviour;
only the first stage becomes real routing.

## Error handling

- Isolate spawn failure → fall back to synthetic. Routing must never block the
  guide, and must never block the alarm.
- No path found (disconnected origin) → empty result → synthetic fallback.
- Search exceeding a time budget → return best-so-far rather than hang.

## Testing

Pure Dart, no plugins, consistent with the existing 101 tests.

1. Hand-built fixture with a **known** optimal path — asserts correctness, not
   merely that something returned.
2. Transfer penalty provably changes the selected route.
3. A competitive direct route is preferred over a 2-leg one.
4. Boarding cap enforced: no path exceeds 3 transfers.
5. Fare on a 2-leg path charges **two** base fares, not one.
6. Disconnected origin returns empty (triggers fallback).
7. Performance guard: full NCR search within a fixed budget.

## Known limitations

- The 3-transfer cap can miss an exotic 4-leg route.
- The fare proxy may pick a marginally sub-optimal path (fare shown is exact).
- No timetables in the feed, so `boardingWaitMin` is a flat headway assumption,
  not a real schedule.
- UV Express remains synthetic.
