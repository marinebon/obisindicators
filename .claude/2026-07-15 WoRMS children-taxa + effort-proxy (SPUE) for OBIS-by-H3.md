# Plan: WoRMS children-taxa + effort-proxy (SPUE) for OBIS-by-H3

## Context

Matt Biddle (NOAA/IOOS) replied to the "OBIS biodiversity by H3 hexagon" app
(`apps/h3-db`) wanting to filter OBIS by **WoRMS AphiaID and grab all children taxa
at any rank** — e.g. all diatoms (class *Bacillariophyceae*) for PACE, or an
arbitrary rank like Infraorder *Cetacea* — using only the local OBIS snapshot, not
the heavy OBIS web services. Ben's reply names the path: load the **full WoRMS
taxonomy** (from `MarineSensitivity/workflows/ingest_taxon.qmd`) and port calcofi4r's
`get_taxon_children()` recursive walk. Scientific motivation: an **effort proxy** —
a higher-order taxon's record count (e.g. all Cetacea, from multi-species surveys)
becomes the *denominator* for a species' records, a presence-only CPUE/SPUE.

Delivers: (1) children-taxa resolution in `obisindicators` + the `h3-db` app,
(2) a vignette on children taxa + the SPUE effort proxy, (3) a vignette on scaling
across H3 resolutions, (4) a plumber `/h3` API endpoint + full server re-enablement.

## Decisions (confirmed with user)
1. **Bake a WoRMS `taxon` table into `obis_h3.duckdb`**; serve arbitrary-rank children
   maps via `WITH RECURSIVE` in the tile SQL (the h3t validator allows it).
2. **SPUE denominator = user-specified effort taxon** (default = target's parent class).
3. **Full API + server re-enablement now** (DuckDB-backed plumber, deploy on msens).
4. **Global store already exists** on msens to develop/verify against.

## Key findings from research
- **`occ_h3` already carries `aphiaid`** (BIGINT, species-level) — `R/h3t.R:195`. Global
  store present: `/share/data/obis/obis_h3.duckdb` → `obis_h3_global_v20260708.duckdb`
  (3.5 GB). *Verify aphiaid is actually populated* (first verification step).
- **`idx_h3_taxon` only precomputes phylum/class/order** — arbitrary ranks must resolve
  the AphiaID subtree and filter `occ_h3.aphiaid IN (...)` on the live path.
- **h3t validator allows `WITH RECURSIVE`** (`server/h3t/app/sql_validate.py` rule 3;
  final projection must be `cell_id,value[,n]`) → children map = a served tile query,
  given the `taxon` table is in the same read-only store.
- **Reference** — `calcofi4r::get_taxon_children()` (`R/functions.R:11`),
  `cc_match_ichthyo_by_taxon()` (`R/match.R:483`): recursive `parentNameUsageID` walk.
  WoRMS table has `taxonID`(=AphiaID), `parentNameUsageID`, `acceptedNameUsageID`,
  `scientificName`, `taxonRank`. Source is `ingest_taxon.qmd`'s `worms` table in
  `spp.duckdb` — **exact path on msens still to confirm** (not under `/share/data` as
  probed; likely built via workflows). Resolve before the bake step.
- **Server**: Caddy *already* routes `api.marinesensitivity.org → plumber:8888`
  (`caddy/Caddyfile:14`); `run-api.R` already serves `:8888`. The `plumber`+postgis
  services are commented out in `server/docker-compose.yml`. `api/plumber.R` eagerly
  `source()`s a **postgres `con`** (`workflows/libs/db.R`) at load → must be made lazy
  so a DuckDB-only API boots. `h3t` service is the working DuckDB-backed model.
- R is not on the msens host PATH — it runs inside the `rstudio`/`plumber` containers
  (`docker exec`). Verification commands must use the container.

## Design

### A. `obisindicators` package — core logic (with tests, per CLAUDE.md parity rule)
- **New `R/taxon.R`**:
  - `obis_taxon_children(aphiaid, con)` — port of `get_taxon_children()`; recursive CTE
    over `taxon(parentNameUsageID)`; returns taxonID/scientificName/taxonRank/depth.
    Single source of truth, unit-tested on a synthetic 3-level fixture.
  - `obis_taxon_subtree_sql(aphiaid)` — returns the `WITH RECURSIVE taxon_tree AS (...)`
    CTE string for embedding in served SQL.
- **Extend `R/h3t.R` `obis_h3t_sql()`**: add `aphiaid=` filter (single/vector). When set,
  prepend the recursive CTE and filter the live `occ_h3` path with
  `aphiaid IN (SELECT taxonID FROM taxon_tree)`. Existing rank/preset paths unchanged.
- **Effort proxy** (`R/taxon.R`): `calc_spue()` (R reference) + `obis_spue_sql(num_aphiaid,
  den_aphiaid=<parent class default>)` → per-cell `value = records(numerator subtree) /
  records(effort subtree)`. Pin SQL↔R with a parity test (mirrors the existing
  `calc_indicators()`↔h3t contract).
- **Build/migrate**: new `data-raw/migrate_add_taxon.R` + a step in
  `data-raw/build_obis_h3_duckdb.R` to load the WoRMS `taxon` subset into
  `obis_h3.duckdb`, indexed on `parentNameUsageID` (and `taxonID`). Writes a new file,
  swaps the symlink, restarts h3t, bans Varnish (same pattern as existing build driver).
- Register `taxon` in `_pkgdown.yml`; update `apps/h3-db/schema_cols.csv` + `schema_erd.mmd`.

### B. `apps/h3-db/app.R` — UI
- Add an "AphiaID / any-rank taxon" control (name→AphiaID lookup against `taxon`), wired
  through `obis_h3t_sql(aphiaid=)`; show resolved child count. Optional EOV presets from
  IOOS `eov_taxonomy` CSVs. Reuses the existing SQL/URL/`maplibre_proxy` flow.

### C. Vignettes (`obisindicators/vignettes/`)
- **`taxon_children.Rmd`** — resolve children of an arbitrary taxon (Cetacea,
  Bacillariophyceae); map records; build the SPUE proxy (species ÷ user-chosen effort
  taxon) per H3 cell; interpret.
- **`scaling.Rmd`** — one query across H3 res 1–7: cell counts, record density, live-query
  latency vs precomputed layers, zero-inflation/sparsity of the SPUE denominator; guidance
  on precompute-vs-recurse-live (informs whether to add a descendant-closure table later).

### D. `MarineSensitivity/api` + `server` — plumber endpoint + re-enablement
- **`api/plumber.R`**: make the postgres `con` **lazy** (guard the two postgres endpoints so
  boot doesn't require postgis). Add `GET /h3` → H3 summary for `query`/`taxon`/`aphiaid`,
  `level` (H3 res), `extent` (bbox WKT; default global), `format` ∈
  {geojson, gpkg, csv, parquet, geoparquet}. Reuses `obis_h3t_sql()` +
  `obis_taxon_subtree_sql()`; adds `h3_cell_to_boundary_wkt()` geometry for geo formats;
  emits via DuckDB `COPY`/`sf::st_write`. Read-only against `obis_h3.duckdb`.
- **`server/`**: rewrite/uncomment the `plumber` service in `docker-compose.yml`
  (DuckDB-backed, mount `/share`, `:8888`, **no** postgis `depends_on`); add `duckdb` to
  `plumber/Dockerfile` install2.r. Caddy route already exists. Deploy:
  `ssh msens`, `docker compose up -d --build plumber`.

## Files to create / modify
- `obisindicators/R/taxon.R` (new), `R/h3t.R`
- `obisindicators/tests/testthat/test-taxon-children.R`, `test-spue-parity.R` (new)
- `obisindicators/data-raw/migrate_add_taxon.R` (new), `data-raw/build_obis_h3_duckdb.R`
- `obisindicators/vignettes/taxon_children.Rmd`, `vignettes/scaling.Rmd` (new); `_pkgdown.yml`
- `MarineSensitivity/apps/h3-db/app.R`, `schema_cols.csv`, `schema_erd.mmd`
- `MarineSensitivity/api/plumber.R`; `server/docker-compose.yml`, `server/plumber/Dockerfile`

## Verification
- **Pre-flight**: `docker exec` Rscript on msens to confirm `occ_h3.aphiaid` is populated and
  locate the WoRMS source for the `taxon` bake.
- `devtools::test()` — children recursion + SPUE parity on synthetic fixtures (red = stop).
- Build a tiny DuckDB (fake `taxon` tree + `occ_h3`); assert `obis_h3t_sql(aphiaid=)` returns
  the expected cells; round-trip via `obis_h3t_url()`.
- Migrate on msens → new store; `curl h3t/stats?q=<children SQL>` renders (e.g. Cetacea).
- App: run locally against the global store; verify a Cetacea / Bacillariophyceae map + SPUE.
- API: `curl "/h3?taxon=Cetacea&level=4&format=geoparquet"` (and each format); open in `sf`.
- Deploy: rebuild `plumber` + `h3t` on msens, ban Varnish cache; hit `api.marinesensitivity.org/h3`.
