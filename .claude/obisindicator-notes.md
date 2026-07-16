

## 2026-07-15 children taxa, api, SPUE, scaling vignettes

Read the email thread with Matt Biddle SU: "OBIS biodiversity by H3 hexagon". See if you can tease out the children taxa for
  implementation (see @../../CalCOFI/calcofi4r/) in the @../../MarineSensitivity/apps/h3-db/ app (deploy with `ssh msens` to
  `/share/github/MarineSensitivity/apps/`). The full WoRMS download (except algae) was handled by
  @../../MarineSensitivity/workflows/ingest_taxon.qmd. Build a vignette to look at children taxa and develop a observations per
  unit effort proxy with higher order taxa to a given species. Build another vignette tackling scaling issues as we look at
  observations across H3 skills. Consider adding an R plumber API endpoint to @../../MarineSensitivity/api/ (which would need to
  get turned on at server with @../../MarineSensitivity/server/ since decommissioning the older Postgres based API endpoints) for
  generating H3 summaries for given query, level, extent (default to global) and output format (GeoJSON, geopackage, csv,
  parquet, geoparquet, ...)

----

PLAN: `.claude/plans/2026-07-15 WoRMS children-taxa + effort-proxy (SPUE) for OBIS-by-H3.md`

----

All eight tasks are complete and the feature is live in production. Here's the final picture.

What shipped

Matt Biddle's ask — filter OBIS by any WoRMS taxon at any rank and grab all children, from the local snapshot, for effort-normalized indicators — is now a working capability across the stack.

obisindicators (pushed to main, devtools::test() → 74 pass)
- R/taxon.R: obis_taxon_children() (recursive WoRMS walk), obis_taxon_subtree_sql(), calc_spue() + obis_spue_sql().
- obis_h3t_sql(aphiaid=) — arbitrary-rank children maps via WITH RECURSIVE.
- Parity tests pinning calc_spue() ↔ obis_spue_sql(); two vignettes; build/migrate scripts; updated CLAUDE.md, _pkgdown.yml.

App / API / server (all pushed + deployed on msens)
- h3-db app: "Children of a WoRMS AphiaID" control.
- GET /h3: H3 summaries by taxon/aphiaid/level/extent in geojson · gpkg · csv · parquet · geoparquet, plus SPUE mode; postgres con made lazy.
- DuckDB-backed plumber service re-enabled (postgres stack stays retired).

Verified live on the real 28 M-record store

- Store: taxon (1.56 M WoRMS rows) baked in; symlink swapped; old store kept for rollback.
- h3t service: Cetacea (AphiaID 2688) children map → 14,963 cells.
- App: HTTP 200, new control served.
- API: api.marinesensitivity.org/h3 → 200; CSV/GeoJSON/GeoParquet + SPUE all return real data.

Two bugs caught by testing on real data (both fixed)

1. SPUE NULL-vs-0: SUM(...) FILTER returns NULL where calc_spue() returns 0 for effort-cells lacking the target — fixed with COALESCE, and I added the fixture case that would have caught it.
2. HUGEINT export: SUM() yields HUGEINT, which the GDAL writer rejects — fixed by casting value::DOUBLE, n::BIGINT.

Notes for you

- The apps checkout is pinned to branch v7; since its h3-db files were byte-identical to main's pre-commit state, I deployed the app via a scoped git checkout origin/main -- h3-db/… overlay (no branch switch). You may want to reconcile that pin later.
- The plumber image needed duckdb ≥ 1.5 (rocker's pinned snapshot ships 1.1.1) — pushed a Dockerfile fix installing the latest binary.
- taxon.parquet is parked at /share/data/derived/taxon.parquet so the build driver's bake_taxon() auto-includes it on the next global rebuild.

The scaling vignette's caveat showed up for real in the SPUE output (bright value=1 cells backed by n=1) — worth a look when you and Matt discuss the effort-proxy paper.