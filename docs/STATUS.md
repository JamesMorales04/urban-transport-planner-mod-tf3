# Urban Tram Planner — STATUS

Maintained per iteration. Sources of truth (in order): current code, real TF3
logs, official/community TF3 modding docs, vanilla game scripts, then reasoned
inference. No imagined APIs.

## Implemented (v0.6, verified)

- Street tram detection with the CORRECT modes: `TRAM` / `ELECTRIC_TRAM` on
  lane `transportModes` (map form `{Mode: boolean}`, value must be `true`;
  list form tolerated for on-disk content). Verified against
  `base/content/infrastructure/street.zip` (e.g. `town_new_large_tram_electrified`
  has 2/8 lanes with `CAR,BUS,TRUCK,TRAM,ELECTRIC_TRAM`).
- Street-only inventory: `roadType == STREET` required (runtime enum and
  on-disk string forms). Rail `TRACK` templates (`TRAM_TRACK` /
  `ELECTRIC_TRAM_TRACK`, `track.zip`) are counted for diagnostics and NEVER
  offered as street targets.
- Car-access preservation: a street with `CAR` lanes is never mapped to a
  car-free tramway (e.g. 2-lane street → `tram_new` pure tramway rejected).
- Structural compatibility: same lane count, same forward count, same known
  `roadType`/`country`, conservative width/offset/style/cost scoring.
- P95 urban radius from town buildings (`townBuildingSystem.getTown2BuildingMap`,
  used from GUI thread exactly like vanilla `town.tl` / `marketing_display`).
- Street graph scan via `octree.findEntitiesInCircle` + `BASE_EDGE` /
  `BASE_EDGE_STREET`; construction-linked edges skipped via
  `streetConnectorSystem.getConstructionEntityForEdge`.
- Radial corridor: densest outer sector target + Dijkstra (satisfying edges
  preferred, objects penalized) between centre and periphery edges.
- Proposals: ONLY `api.engine.util.proposal.replaceSegment(entity, template)`
  → `makeProposalData` validation → `makeWorldBuildProposalCmd(proposal,
  context, ignoreErrors=false, playerInitiated=true, doDust=true)` sequential
  send. No `BaseEdge.laneConfigs` writes, no `LaneConnection.withTram`, no
  `Proposal` mutation. Build button only when every segment validates.
- Build hardening: per-segment entity re-resolution (`refreshEdge`), rebuild
  aborts on world-changed/rejected segment instead of continuing blindly.
- Bridges/tunnels (`BaseEdgeType != NORMAL`) excluded and counted.
- `modinfo.json` fixed to vanilla schema (`authors: [{name, role}]`); was
  failing every load with `Failed to parse modinfo.json`.
- `mod.json` normalized (revision 6, severity/cosmetic/runScript fields).
- Modular code: `utp_logger`, `utp_street_catalog`, `utp_city`,
  `utp_proposal`, thin `urban_transit_core` facade (plugin API unchanged).
- Unit tests: `tests/run_tests.lua` (`lua tests/run_tests.lua`), 31 checks,
  engine-independent with stubbed `api`.

## Partially implemented

- Corridor conversion end-to-end: code path complete and validated statically,
  awaiting the in-game acceptance test (rails visible + vanilla tram paths it).
- Electric preference with non-electric fallback flag (`electricFallbacks`).

## Pending (in dependency order)

1. In-game acceptance of v0.6 radial conversion (manual: analyze → build →
   vanilla stops + manual tram line paths the corridor).
2. Stop planner (spacing, density, coverage, interchanges; no duplicates).
3. Line planner (connectivity check before creation; ring vs radial sense).
4. Vehicle planner (compatible tram discovery, count from length/stops/demand).
5. Ring / Hybrid / Auto topology on top of the proven primitive.
6. Bus feeders (coverage gaps → interchange terminals).
7. Cargo / CITY SUPPLY analysis (separate network where appropriate).
8. Persistent manifest (semantic, survives entity-ID churn) + KEEP / EXTEND /
   MOVE / ADD / RETIRE reconciliation + manual-change respect + Force rebuild
   + incremental recalculation.

## Known issues

- `replaceSegment` on streets is documented ("Use with caution") but has ZERO
  shipped vanilla callers; behavior on bridges/tunnels/one-ways/modded streets
  is unproven → excluded or validated per segment, never assumed.
- `makeProposalData` from GUI thread has no vanilla caller to copy; wrapped in
  `pcall`, failures block Build instead of crashing.
- Modded streets: mapping degrades to incompatible → excluded with counts;
  no destructive fallback.
- Sequential builds can shift later entity IDs → mitigated by `refreshEdge`
  + pre-send revalidation + abort; no multi-segment atomic transaction exists
  in the API.

## API uncertainties (encapsulated, marked)

- Exact `ResName` string form expected by `replaceSegment` for street
  templates (`::/infrastructure/street/...street_template` assumed from
  `street_constructions` tables; no shipped caller).
- Whether `replaceSegment` preserves node/lane-connection topology on all
  street families (validator is the authority per segment).
- No public script entry for `ACTION_TRAM_TRACK_TOOL` / `TramTrackType`
  application; mods either expose the tool in GUI or use `replaceSegment`.
- `transportModesStreet` on runtime templates: checked when present, lanes
  are authoritative.

## Architecture decisions

- v0.4 approach (mutate `BaseEdge.laneConfigs` / `LaneConnection.withTram`)
  is REJECTED: engine bindings are read-only there.
- v0.5 approach (StreetTemplate + replaceSegment) kept, but its mode filter
  (`TRAM_TRACK`) was wrong; fixed to `TRAM`/`ELECTRIC_TRAM` in v0.6.
- `catenaryAdd` is NOT followed for streets (verified: 0 hits in street.zip;
  only track.zip uses it). Electrification = distinct `*_tram_electrified`
  template with `ELECTRIC_TRAM` lanes.
- `makeWorldBuildProposalCmd` arg order is
  `(proposal, context, ignoreErrors, playerInitiated, doDust?)` per
  `api/tealdef/api/cmd.d.tl:961`; vanilla 4-arg call `(proposal, nil, false,
  true)` confirms it. The v0.5 comment stating a different order was fixed.
- GUI-thread reads (`getComponent`, `octree`, `townBuildingSystem`,
  `streetTemplateRep`) mirror vanilla GUI usage; all writes go through
  `api.cmd.sendCommand`.
- `safeField` must preserve `false` (a `ok and v or nil` collapse hid
  `country=false` and disabled the town/country guard; fixed + regression test).

## Next priorities

1. Playtest v0.6 on a save copy (same town as v0.4/0.5 if possible); collect
   panel screenshot + `grep -F "[Urban Tram Planner Alpha]" stdout.txt`.
2. If green: stop planner + manual-line pathing check.
3. If red: classify via new diagnostics (street vs rail counts, mappings,
   first validation error) — never guess.
