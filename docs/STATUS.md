# Urban Tram Planner — STATUS

Maintained per iteration. Sources of truth (in order): current code, real TF3
logs, official/community TF3 modding docs, vanilla game scripts, then reasoned
inference. No imagined APIs.

## Implemented (v0.8, verified)

- v0.7 conversion proven in game (Wahai: 4/4 segments, engine cost $88064).
- v0.8 stops (`utp_stops`): plan from live corridor (converted, >=30 m,
  object-free), era twosided model, sequential borrowed-segment builds,
  continue-on-refusal, station-group discovery + naming.
- v0.8 line + vehicles (`utp_lines`): one radial line in corridor order,
  terminal assignment + passenger config, newest tram, heuristic count,
  `Carrier.TRAM` depot best-effort, manifest log line.

- v0.7 validation redesign (playtest Alteren): `makeProposalData` called on
  `replaceSegment` output throws at runtime
  (`SimpleProposal expected, got Proposal`) and has zero shipped callers, so
  it is NOT called. Validation = creation check at analyze time
  (`replaceSegment` throws on invalid replacement; proposals inert until
  sent) + per-segment `sendCommand` results at build time; actual cost
  accumulates from `resultProposalData.costs`. Vanilla pre-validates inside
  `builtin.ProposalViewer` (`bridge_and_tunnel.tl:130`), no safe equivalent
  for a town-window card.

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

- Full service: corridor proven, stops/line/vehicles implemented but
  awaiting first in-game run (tram visibly serving the line).
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
- `makeProposalData` is NOT called on `replaceSegment` output (runtime
  rejects it; tealdef disagrees; zero shipped callers). Cost is therefore
  engine-reported at build time, not pre-estimated.
- Modded streets: mapping degrades to incompatible → excluded with counts;
  no destructive fallback.
- Sequential builds can shift later entity IDs → mitigated by `refreshEdge`
  + pre-send revalidation + abort; no multi-segment atomic transaction exists
  in the API.

## API uncertainties (encapsulated, marked)

- `makeProposalData` on `replaceSegment` output: RUNTIME-REJECTED
  (`SimpleProposal expected, got Proposal`; tealdef claims otherwise; zero
  shipped callers). Not called since v0.7.
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

1. In-game v0.8 on a save copy: corridor -> paradas (expect N>=2 groups)
   -> linea + tranvias; confirm tram moving with passengers.
2. If red: classify via stop send-messages / group discovery logs.
3. Then: Ring/Hybrid/Auto topology reusing the proven stop+line stack.
