# Urban Tram Planner (alpha)

Automatic urban public-transport planner for Transport Fever 3. Current stage:
prove a safe tram-conversion primitive (existing street → street with tram
tracks via documented `StreetTemplate` + `replaceSegment` proposals), then grow
stops, lines, vehicles, ring/hybrid topologies, feeders, cargo and persistent
reconciliation on top. See `docs/STATUS.md` for the honest state.

## Layout

```text
urban_transport_planner/
  mod.json
  _metadata/modinfo.json        vanilla schema (authors: [{name, role}])
  _metadata/description.html
  content/urban_transit/
    urban_transit_plugin.res.lua    react-plugin ::TownEowExtensionPoint
    urban_transit_plugin.script.lua town-window UI (Analyze / Build)
    urban_transit_core.lua          facade (analyze/build/analyzeSafe/...)
    utp_logger.lua                  uniform logging
    utp_street_catalog.lua          TRAM detection, STREET inventory, scoring
    utp_city.lua                    town shape, street graph, radial corridor
    utp_proposal.lua                replaceSegment, validation, safe executor
  tests/run_tests.lua             engine-independent unit tests
  docs/STATUS.md                  implemented / pending / risks
  CHANGELOG.md
```

## Install

Copy/replace the folder into the TF3 `staging_area` (never merge old files):

```bash
./install.sh "/path/to/Transport Fever 3/staging_area"
```

Then enable the mod and test on a COPY of the save.

## Test procedure (v0.7)

1. Duplicate/manual save. Preferably open the same town as previous tests.
2. Town panel → Urban Tram Planner [ALPHA 0.7].
3. Leave electric preference enabled; press Analyze.
4. Expect: street tram candidates > 0 (not rail tracks), real
   `source -> target` mappings, `lanes to add > 0` on fresh roads,
   `rejected = 0` to enable Build. Pre-build cost shows as pending; the
   real cost is reported by the engine after each segment builds.
5. If rejected > 0: DO NOT BUILD; send panel screenshot + filtered log.
6. If rejected = 0: save again, press Build, verify rails/catenary, then
   place vanilla tram stops + a manual tram line over the corridor. The
   acceptance test is a vanilla tram pathing across it.

Log filter (actual `stdout.txt` in the TF3 user-data log directory):

```bash
grep -F "[Urban Tram Planner Alpha]" /path/to/stdout.txt | tail -n 250
```

## Unit tests (no game needed)

```bash
lua tests/run_tests.lua
luac -p content/urban_transit/*.lua
```

## Versioning

`mod.json` `revision` is the loader's version (currently 7);
`modVersion` mirrors the alpha (`0.7.0`). See `CHANGELOG.md`.
