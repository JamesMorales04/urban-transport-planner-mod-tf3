URBAN TRAM PLANNER ALPHA 0.6
============================
Build date: 2026-10-06

ROOT CAUSE FIXED FROM 0.5
-------------------------
0.5 checked rail modes TRAM_TRACK/ELECTRIC_TRAM_TRACK when looking for
tram streets. Street templates use TRAM/ELECTRIC_TRAM (verified in
street.zip, e.g. town_new_large_tram_electrified: 2 of 8 lanes with
CAR,BUS,TRUCK,TRAM,ELECTRIC_TRAM). TRAM_TRACK belongs to rail TRACK
templates (track.zip). The 0.5 inventory therefore held only the 6 rail
tracks and no street was ever convertible; the logs proved it (every
candidate was ::/infrastructure/track/...).

0.6 detects TRAM/ELECTRIC_TRAM, requires roadType STREET, preserves car
access (a car street is never mapped to a car-free tramway), excludes
bridges/tunnels, no longer follows catenaryAdd for streets (verified:
street.zip has none), and re-resolves + revalidates every segment
sequentially at build time, aborting safely on rejection.

Also fixed: _metadata/modinfo.json used a wrong authors format (plain strings),
which the game
rejected every load (Failed to parse modinfo.json). It now uses the
verified vanilla schema authors:[{name,role}].

WHAT 0.6 DOES
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
recalculation. All reserved until the 0.6 physical conversion passes the
in-game acceptance test (rails visible + vanilla tram pathing).

INSTALL / UPDATE
----------------
Replace the existing urban_transport_planner folder. Do NOT merge.

  ./install.sh "/path/to/Transport Fever 3/staging_area"

TEST PROCEDURE
--------------
1. Duplicate/manual save; same town as before if possible.
2. Town panel -> Urban Tram Planner [ALPHA 0.6].
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
