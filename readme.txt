URBAN TRAM PLANNER ALPHA 0.9
============================
Build date: 2026-10-06

NEW IN 0.8 (stops + line + trams)
----------------------------------
v0.7 proved the conversion end-to-end (Wahai: 4/4 segments, $88064).
0.8 builds on the converted corridor:

1. PLANIFICAR PARADAS: one two-sided stop per converted edge
   (>=30 m, no objects), era model (old/mid/new_twosided), plan only.
2. CONSTRUIR PARADAS: sequential borrowed-segment SimpleProposal builds
   (recipe credited to working mod bus_loops_1), refused stops never sink
   the rest; station groups discovered via before/after diff.
3. CREAR LINEA + TRANVIAS: "<Town> Tranvia" through groups in corridor
   order (game closes the loop out-and-back), getBestLineAssignment +
   passenger stopConfig (shipped line-manager twin), newest tram for sale,
   count = clamp(1, floor(km/500)+1, groups), depot via Carrier.TRAM
   best-effort (line is still created without depot/vehicles).
Stops split their edges, so the line uses stable station groups.

Kept from 0.7: creation-check validation (makeProposalData rejects
replaceSegment output at runtime), sequential safe executor.

ROOT CAUSE FIXED FROM 0.6 (playtest Alteren)
--------------------------------------------
0.6 analysis worked (15 street tram templates, correct
town_new_small -> town_new_small_tram_electrified x3 mapping), but every
segment was refused with:
  "proposal validation failed: bad argument #2 to '?'
   (SimpleProposal expected, got Proposal)"
The engine binding for makeProposalData only accepts SimpleProposal, while
replaceSegment yields a full Proposal. The tealdef signature disagrees, and
no shipped content calls makeProposalData directly (verified by exhaustive
grep: scripts.zip, game_mechanics.zip, gui.zip). The vanilla pre-validation
pattern is builtin.ProposalViewer (bridge_and_tunnel.tl), an engine-backed
component with no safe equivalent for a town-window card.

0.7 therefore validates in two engine-backed steps instead:
  1. creation check: replaceSegment itself throws on invalid replacement
     (proposals are inert until sent, so creating them validates safely);
  2. send result: makeWorldBuildProposalCmd callback per segment, with
     actual cost accumulated from resultProposalData.costs.
Pre-build cost is reported as "lo calcula el motor al construir".

Previous fixes kept: TRAM/ELECTRIC_TRAM detection (not rail TRAM_TRACK),
roadType STREET filter, car-access preservation, bridge/tunnel exclusion,
no catenaryAdd for streets, sequential build with per-segment refresh.

WHAT 0.8 DOES
-------------
Corridor conversion (0.7, proven in game) plus stops, line and trams:

1-7. (As in 0.7: P95 radius, convertible-street graph, street-tram
   inventory, structural scoring, replaceSegment-only conversion,
   sequential safe build, unit tests — now 42 checks.)
8. Stop planning on converted edges (>=30 m, object-free), era twosided
   model, before/after station-group discovery with naming.
9. One radial tram line in corridor order + newest tram for sale +
   depot-aware best-effort purchase/assignment.
10. Manifest log line per built network (town, km, stops, line, vehicles).

FULL TARGET — PRESERVED
-----------------------
Topology Auto/Ring/Radial/Hybrid, stops, lines, vehicles, bus feeders,
cargo/CITY SUPPLY, persistent manifest, KEEP/EXTEND/MOVE/ADD/RETIRE
reconciliation, manual-change respect, Force rebuild, incremental
recalculation. Stops/line/vehicles now exist for the control corridor;
topologies, feeders, cargo and persistence remain until the full service
is proven in game (tram visibly running the line).

INSTALL / UPDATE
----------------
Replace the existing urban_transport_planner folder. Do NOT merge.

  ./install.sh "/path/to/Transport Fever 3/staging_area"

TEST PROCEDURE
--------------
1. Duplicate/manual save; same town as before if possible.
2. Town panel -> Urban Tram Planner [ALPHA 0.9].
3. Analyze; expect street tram candidates > 0, real source -> target
   mappings, lanes to add > 0, rejected = 0.
4. If rejected > 0, DO NOT BUILD; send screenshot + filtered log.
5. If rejected = 0, save, Build, DIAGNOSTICAR + REPARAR CRUCES, then
   PLANIFICAR/CONSTRUIR PARADAS, CREAR LINEA + TRANVIAS. The acceptance
   test is a UTP tram serving the line.

LOG FILTER
----------
  grep -F "[Urban Tram Planner Alpha]" /path/to/stdout.txt | tail -n 250

See docs/STATUS.md for implemented/pending/risks, README.md for layout,
CHANGELOG.md for history.
