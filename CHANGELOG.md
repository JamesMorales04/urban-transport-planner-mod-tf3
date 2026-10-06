# CHANGELOG

## 0.6.0 — tram-detection fix + hardening

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
