# CHANGELOG

## 0.9.0 — spaced stops, coverage, junction repair, tram repurchase

Playtest Alteren (v0.8): stops built and line created, but 4 stops on
0.35 km (too close), tram tracks visually disconnected at crossings, no
tram depot connected (0/1 trams).

- Stops follow bus_loops spacing (CATCHMENT 160 m, SPACING 272 m, MAX 8,
  widest-spread pair guaranteed on short corridors); omitted-close count
  reported. 0.35 km now yields 2 stops, not 4.
- Coverage metric: share of town buildings within 160 m of the corridor,
  in analysis, logs and UI (route-efficiency evidence).
- Junction diagnosis + repair (`utp_junction`): read-only inspection of
  live TRAM lanes per edge and `withTram` connections per shared node;
  guarded repair flips `withTram` false->true on corridor pairs only,
  one proposal per node, re-inspects afterwards. Hypothesis: template
  swap alone leaves junctions at withTram=false (vanilla tool uses
  overrideLaneConfigs instead).
- Depot UX: explicit guidance (build a tram depot on a tram street), and
  COMPRAR TRANVIAS retry on the existing line once connected.
- Feeders/cargo stay scheduled: feeders need a proven trunk; cargo needs
  demand/supply-chain APIs. Not half-implemented.

v0.7 proven in game (Wahai: 4/4 corridor segments, engine cost $88064).
0.8 adds the passenger service on top of the converted corridor:

- Stop planning (`utp_stops`): one two-sided stop per converted edge
  (>=30 m, object-free), era model, plan-then-build staging.
- Stop building: borrowed-segment `SimpleProposal` per stop, sequential,
  refused stops never abort the rest; station groups found via
  before/after `STATION` diff + `EDGE_OBJECT` + `getStationGroup`, named
  `<Town> Tranvia N`. Recipe credited to working mod `bus_loops_1`
  (single source) + vanilla `.con`/tealdef corroboration.
- Line (`utp_lines`): `<Town> Tranvia` through groups in corridor order,
  `getBestLineAssignment(-1, comp, true)` + passenger `stopConfig`
  (shipped `manager_window`/`line_util` twin).
- Vehicles: newest tram for sale (`modelRep` scan), count
  `clamp(1, floor(m/500)+1, groups)`, `Carrier.TRAM` depot best-effort;
  line is created even without depot/vehicles.
- Manifest log line per network; persistent manifest still pending.
- Unit tests now 42 checks green.

v0.6 analysis worked in game (Alteren: 15 street tram templates, correct
`town_new_small -> town_new_small_tram_electrified x3` mapping), but every
segment was refused:
`proposal validation failed: bad argument #2 to '?' (SimpleProposal
expected, got Proposal)`.
`makeProposalData` rejects `replaceSegment` output at runtime despite the
tealdef signature, and no shipped content calls it (verified by exhaustive
grep). Vanilla pre-validates inside `builtin.ProposalViewer`
(`bridge_and_tunnel.tl`), with no safe equivalent for a town-window card.

- Removed the direct `makeProposalData` call. Validation is now:
  creation check (`replaceSegment` throws on invalid replacement; proposals
  are inert until sent) at analyze time, plus per-segment send results at
  build time.
- Actual cost accumulates from `resultProposalData.costs` in send callbacks;
  pre-build cost displays as engine-pending.
- Fixed missed `[ALPHA 0.5]` card title (-> 0.7).
- `mod.json` revision 7 / `modVersion` 0.7.0.

Root cause (v0.5): street tram detection checked rail modes
`TRAM_TRACK` / `ELECTRIC_TRAM_TRACK`. Street templates use
`TRAM` / `ELECTRIC_TRAM`; rail modes belong to `track.zip` (`roadType TRACK`).
The v0.5 inventory therefore contained only the 6 rail tracks, no street was
ever convertible, and analysis could never yield a corridor (proven by logs:
all 6 candidates were `::/infrastructure/track/...`).

- Inventory now requires `roadType STREET` + real `TRAM`/`ELECTRIC_TRAM` lanes;
  rail tracks counted for diagnostics only, never targets.
- Car-access preservation guard (street → car-free tramway rejected).
- `country`/`roadType` guards actually work (`safeField` false-collapse fixed).
- Bridges/tunnels excluded + counted (`BaseEdgeType`).
- `catenaryAdd` no longer followed for streets (verified absent in street.zip).
- `makeWorldBuildProposalCmd` comment fixed to the verified signature
  `(proposal, context, ignoreErrors, playerInitiated, doDust?)`.
- Build re-resolves + revalidates every segment sequentially, aborts safely.
- `modinfo.json` fixed to vanilla schema (was `Failed to parse` every load).
- Code split: `utp_logger` / `utp_street_catalog` / `utp_city` /
  `utp_proposal` + thin `urban_transit_core` facade (plugin API unchanged).
- UI v0.6 with corrected diagnostics; `docs/STATUS.md`, `README.md`, unit
  tests (`tests/run_tests.lua`, 31 checks green).

## 0.5.0 — documented-proposal corridor (broken detection)

Replaced v0.4 direct `BaseEdge.laneConfigs` mutation with
`replaceSegment` + `makeWorldBuildProposalCmd` validation, sequential build,
P95 radius, radial corridor, template scoring. Kept the wrong
`TRAM_TRACK`-for-streets filter — fixed in 0.6.0.

## 0.4 and earlier

Iterative alphas; v0.4 failed with `assign BaseEdge.laneConfigs` (engine
bindings are read-only there). Approach rejected, not revived.
