URBAN TRAM PLANNER ALPHA 0.7
============================
Build date: 2026-10-06

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

WHAT 0.7 DOES
-------------
Same staged scope as 0.5 (one radial control corridor) plus:

1. P95 urban radius from town buildings.
2. Street graph from convertible-or-already-tram STREET edges only.
3. Real street-tram inventory with street/rail diagnostics.
4. Structurally compatible source -> target scoring (lanes, forward,
   roadType, country, car access, width/offset/style/cost).
5. replaceSegment proposals only; makeProposalData validation gates Build.
6. Sequential build with per-segment entity refresh + revalidation.
7. Unit tests: lua tests/run_tests.lua (31 checks, no game needed).

FULL TARGET — PRESERVED
-----------------------
Topology Auto/Ring/Radial/Hybrid, stops, lines, vehicles, bus feeders,
cargo/CITY SUPPLY, persistent manifest, KEEP/EXTEND/MOVE/ADD/RETIRE
reconciliation, manual-change respect, Force rebuild, incremental
recalculation. All reserved until the 0.7 physical conversion passes the
in-game acceptance test (rails visible + vanilla tram pathing).

INSTALL / UPDATE
----------------
Replace the existing urban_transport_planner folder. Do NOT merge.

  ./install.sh "/path/to/Transport Fever 3/staging_area"

TEST PROCEDURE
--------------
1. Duplicate/manual save; same town as before if possible.
2. Town panel -> Urban Tram Planner [ALPHA 0.7].
3. Analyze; expect street tram candidates > 0, real source -> target
   mappings, lanes to add > 0, rejected = 0.
4. If rejected > 0, DO NOT BUILD; send screenshot + filtered log.
5. If rejected = 0, save, Build, verify rails/catenary, then vanilla
   stops + manual tram line over the corridor.

LOG FILTER
----------
  grep -F "[Urban Tram Planner Alpha]" /path/to/stdout.txt | tail -n 250

See docs/STATUS.md for implemented/pending/risks, README.md for layout,
CHANGELOG.md for history.
