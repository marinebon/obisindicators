# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working
with code in this repository.

> General R-package conventions (roxygen2,
> `devtools::document/build/install/test`, code style, the “keep
> scientific logic in the package so it is testable” rule) live in the
> parent `/Users/bbest/Github/CLAUDE.md`. This file is the repo-specific
> overlay: architecture, the parity contract, and gotchas.

## What this package is

`obisindicators` turns OBIS occurrence data into marine biodiversity
indicators (ES50/Hurlbert, species richness, Shannon, Simpson, Hill
numbers, record counts) binned onto [H3](https://h3geo.org) hexagons.
There are **two computational paths that must agree**:

1.  **In-memory / static** — for analysis and static maps.
    [`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md)
    (a dplyr pipeline) is the reference implementation of the math;
    occurrences are gridded with
    [`make_hex_res()`](https://marinebon.org/obisindicators/reference/make_hex_res.md) +
    [`h3::geo_to_h3()`](https://rdrr.io/pkg/h3/man/geo_to_h3.html) and
    drawn with
    [`gmap_indicator()`](https://marinebon.org/obisindicators/reference/gmap_indicator.md)
    (ggplot + Robinson projection). This is what the `obisindicators`,
    `resolution`, `temporal_subsets`, and `regional_diversity` vignettes
    demonstrate against the shipped `occ_*` datasets.

2.  **DuckDB / served tiles (`h3t`)** — the same indicator math
    re-expressed in SQL so it can be precomputed into a DuckDB store and
    served as on-demand H3 map tiles. Lives in `R/h3t.R`. See
    [`vignette("h3t")`](https://marinebon.org/obisindicators/articles/h3t.md).

### The parity contract (do not break)

The SQL in `R/h3t.R` (`.h3t_idx_sql`, `.h3t_idx_taxon_sql`, and the live
paths in `obis_h3t_sql`) is a **translation of
[`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md)
with `esn = 50`**. `tests/testthat/test-h3t-parity.R` builds a small
DuckDB store from shipped `occ_SAtlantic` and asserts the SQL output
matches
[`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md)
cell-for-cell (exact for `n`/`sp`, tight tolerance for shannon/simpson,
1e-3 for `es` due to `lgamma` float). **If you change the indicator
formula in one place, change it in the others and keep these tests
green.** The ES(n) term appears in **five** spots:
[`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md)
(`R/analyze.R`), `.h3t_idx_sql`, `.h3t_idx_taxon_sql`, the `es` branch
of `obis_h3t_sql` (all `R/h3t.R`), and `.h3t_idx_eov_sql` (`R/eov.R`,
pinned by `test-eov-parity.R`).

## The h3t store & serving pipeline

`build_obis_h3_duckdb(src, path_duckdb, ...)` reads occurrences (a
`data.frame` **or** parquet path(s)/glob(s) / `s3://` URLs read via
DuckDB `httpfs`), bins to H3 res 7, and writes three layers:

- `idx_h3` — precomputed **all-taxa** indicators, res 1–7 (fastest tile
  path). Carries `hex_prune` and is clustered by
  `(res, hex_prune, cell_id)`.
- `idx_h3_taxon` — precomputed **per-taxon** indicators for coarse ranks
  only (phylum/class/order — `H3T_IDX_RANKS`); finer ranks would explode
  storage. Clustered by `(rank, taxon, res)` (no spatial prune — it’s
  already small).
- `occ_h3` — **species-level** counts at resolution tiers 3/5/7
  (`H3T_RES_TIERS`), carrying `hex_prune` and clustered by
  `(res, hex_prune, cell_id)`; used for live taxon/year/aphiaid-filtered
  queries.

**Automatic per-tile spatial pruning (`hex_prune`).** The tile bbox is
fully determined by the `z/x/y` tile address, so the client never states
it. Zonemaps live on stored columns, so `occ_h3`/`idx_h3` materialize a
**coarse H3-parent** key
`hex_prune = h3_cell_to_parent(cell_id, LEAST(res, H3T_PRUNE_RES))` (res
3) and are clustered by `(res, hex_prune, cell_id)`. The `h3t` server
derives each tile’s covering res-`H3T_PRUNE_RES` cells from `z/x/y`
(`prune.covering_cells`, a dedicated in-memory DuckDB `h3` — canonical
ids, no version drift with the R build) and **rewrites the query’s AST**
(`prune.inject_prune`) to add `hex_prune IN (...)` to any scan of a
table carrying that column — pruning row groups to the tile in 2D
instead of aggregating the whole layer **per tile**. Injection is
skipped for tiles coarser than `PRUNE_RES` or when the covering set
exceeds `MAX_COVER_CELLS`; correctness is always held by the outer
centroid filter (`wrap_tile_sql`), so pruning is a pure speed-up.
`test-h3t-prune.R` asserts it is **result-preserving**. **Changing
`H3T_PRUNE_RES` or the prune column means keeping
[`build_obis_h3_duckdb()`](https://marinebon.org/obisindicators/reference/build_obis_h3_duckdb.md),
`config.PRUNE_RES`, `prune.covering_cells`/`inject_prune` (both
`server/h3t` and `CalCOFI/api-h3t-py`), and `test-h3t-prune.R` in
agreement.** Clients emit plain SELECTs — no `bbox_placeholder`; the
earlier `{{bbox}}` token is still stripped server-side
(`tiles.strip_bbox_placeholder`) for any cached URLs.

`obis_h3t_sql(indicator, taxon, aphiaid, years, ...)` composes the
read-only `SELECT` (projecting exactly `cell_id, value, n`, with a
`{{res}}` placeholder the server substitutes per tile). It **routes to
the fastest layer**: no filter → `idx_h3`; single coarse-rank value, no
years → `idx_h3_taxon` (no `hex_prune`, so never injected — already
small); an `aphiaid` filter → live `occ_h3` filtered to the WoRMS
subtree (see below); anything else finer/multi-value/year-ranged → live
aggregation over `occ_h3`.
[`obis_h3t_url()`](https://marinebon.org/obisindicators/reference/obis_h3t_url.md)
base64-encodes that SQL into the tile URL’s `?q=`. The consuming service
is `MarineSensitivity/server/h3t` (a vendored [h3t tile
factory](https://github.com/CalCOFI/api-h3t-py)), rendered by
[`mapgl::add_h3t_source()`](https://walker-data.com/mapgl/reference/add_h3t_source.html).

## Taxonomy children & the SPUE effort proxy (`R/taxon.R`)

`occ_h3` carries only the six DwC rank columns plus a species-level
`aphiaid`, so a filter on an **arbitrary rank** (e.g. Infraorder
*Cetacea*) isn’t possible from `occ_h3` alone. `R/taxon.R` adds a WoRMS
**`taxon`** table (baked into the store — see below) and walks it:

- `obis_taxon_children(aphiaid, con)` — recursive CTE down
  `parentNameUsageID`; returns the seed + all descendants (port of
  `calcofi4r::get_taxon_children()`).
- `obis_h3t_sql(aphiaid=)` prepends a
  `WITH RECURSIVE taxon_tree AS (...)` CTE and filters
  `occ_h3.aphiaid IN (SELECT taxonID FROM taxon_tree)`. The h3t
  validator **explicitly allows `WITH RECURSIVE`**, so children maps are
  served as tiles.
- `obis_spue_sql(num_aphiaid, den_aphiaid)` — the effort proxy: per-cell
  `records(target subtree) / records(effort subtree)`, restricted to the
  effort taxon’s footprint (a presence-only SPUE).
  [`calc_spue()`](https://marinebon.org/obisindicators/reference/calc_spue.md)
  is its **pinned R reference** (`test-spue-parity.R`), same discipline
  as
  [`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md).

The `taxon` table is produced by `data-raw/build_taxon_parquet.R` (WoRMS
DwC `taxon.txt` → `taxon.parquet`, stripping the `urn:lsid:…:taxname:`
prefix to an integer `taxonID` = AphiaID) and baked into
`obis_h3.duckdb` by `data-raw/migrate_add_taxon.R` (or `bake_taxon()` in
the build driver). AphiaIDs are integer-validated (`.h3t_aphiaid_ints`),
the injection guard for the id-list.

**The bulk download is not a complete cover** (`R/taxon_gapfill.R`). On
the 2026-07 global store 12,021 of 167,190 distinct `occ_h3.aphiaid`
values (~7%, 8.3M of 121.9M records) were absent from `taxon` — notably
algae, whose WoRMS records come from thematic databases the DwC export
lags — making them invisible to every children/EOV/SPUE query.
[`obis_taxon_orphans()`](https://marinebon.org/obisindicators/reference/obis_taxon_orphans.md)
reports the gap and
[`obis_taxon_fill_gaps()`](https://marinebon.org/obisindicators/reference/obis_taxon_fill_gaps.md)
closes it by supplementing the bulk join with per-id WoRMS REST lookups
([`wm_aphia_records()`](https://marinebon.org/obisindicators/reference/wm_aphia_records.md),
the `AphiaRecordsByAphiaIDs` operation at 50 ids/request, in parallel —
same pattern as `msens::wm_rest()`). **The fill must run to transitive
closure**: inserting an orphan whose ancestors are also missing leaves
it disconnected from any seed above it, so each round re-chases
newly-dangling parents. It warns and returns `closed = FALSE` rather
than implying a whole tree when `max_rounds` is hit (a real WoRMS chain
needs ~14 rounds; the default is 40). `fetch` is the injectable seam the
tests use to run offline.

## EOVs (`R/eov.R`)

GOOS/IOOS biology & ecosystems **Essential Ocean Variables** are defined
taxonomically, and the IOOS Marine Life Data Network publishes that
definition as root AphiaIDs per EOV
([`eov_taxonomy/IdentifierList.csv`](https://github.com/ioos/marine_life_data_network/tree/main/eov_taxonomy))
— 33 seeds across 7 EOVs. That is exactly a multi-seed `aphiaid`
subtree, so `OBIS_EOV` holds the seeds,
[`obis_eov_sql()`](https://marinebon.org/obisindicators/reference/obis_eov_sql.md)
builds the tile SQL, and
[`obis_eov_bake()`](https://marinebon.org/obisindicators/reference/obis_eov_bake.md)
adds two layers: `eov` (`eov, taxonID` membership, seeds expanded over
`taxon`) and `idx_h3_eov` (precomputed indicators per `(eov, res)`, res
1–7, clustered by `(eov, res, cell_id)`; no `hex_prune` — like
`idx_h3_taxon` it is already small). Routing mirrors `obis_h3t_sql`: one
EOV and no years → `idx_h3_eov`; years, several EOVs, or `live = TRUE` →
live subtree.

**Why seeds-and-subtree rather than the DwC rank columns**: the rank a
name occupies is not stable, so a `class = <name>` filter silently
matches *nothing* when OBIS files the name elsewhere. Measured on the
global store: `class='Actinopterygii'` → 0 records (WoRMS ranks it a
Gigaclass; OBIS’s class is `Teleostei`, 44.2M) and `class='Anthozoa'` →
0 (a Subphylum; OBIS uses `Hexacorallia`/`Octocorallia`). Both were live
bugs in the h3-db app’s presets. Subtree walking is rank-agnostic and
immune. EOV membership is only as complete as `taxon`, so run the
gap-fill first.

### h3t gotchas

- **SQL injection**: taxon/year predicates are built by
  `.h3t_where_clause()` + `.h3t_sql_quote()` (single-quote escaping) —
  never interpolate user strings into h3t SQL any other way. There is a
  regression test for `' OR '1'='1`.
- **`order` is a SQL reserved word** — always quoted as `"order"`.
- **H3 cell ids exceed R double precision (2^53)** — carried as `BIGINT`
  in DuckDB; join/compare on the hex *string* (`h3_h3_to_string`) in R,
  as the parity test does.
- **OBIS open-data parquet nests DwC fields in an `interpreted`
  struct**; `dropped`/`absence` stay top-level.
  [`build_obis_h3_duckdb()`](https://marinebon.org/obisindicators/reference/build_obis_h3_duckdb.md)
  probes the schema from **one** sample file (not the whole glob — 6900+
  files would OOM) and handles both flat and nested layouts. Column
  matching is case-insensitive (`col_match`).
- **Resource guards for big scans**: `memory_limit`, `threads`,
  `temp_dir`, `max_temp_dir_size`. A global S3 scan (~96 GB) will
  OOM/wedge the host without them — always pass them for parquet/S3
  sources.

## Commands

Standard R-package dev per the parent CLAUDE.md. Repo-specific:

``` r

# run a single test file
testthat::test_file("tests/testthat/test-h3t-parity.R")

# the parity/h3t tests need DBI, duckdb, glue, gsl AND a one-time network
# download of the duckdb `h3` community extension; they skip gracefully if any
# is unavailable (CI installs deps but may skip the extension).
devtools::test()
```

``` bash
# build the authoritative h3t DuckDB store (server-side driver). Always builds a
# demo store from shipped occ_SAtlantic; auto-builds a global store if local
# parquets exist at /share/data/obis/occurrence, or force S3 with OBIS_GLOBAL=true.
Rscript data-raw/build_obis_h3_duckdb.R

# add the idx_h3_taxon layer to an EXISTING store (no S3 re-read, writes a new file)
Rscript data-raw/migrate_add_idx_h3_taxon.R <in.duckdb> <out.duckdb> [--cluster-occ]

# extract the WoRMS taxonomy subset (run where the WoRMS taxon.txt lives), then
# bake it into a store so aphiaid children/SPUE queries work (writes a new file)
Rscript data-raw/build_taxon_parquet.R [taxon.txt] [taxon.parquet]
Rscript data-raw/migrate_add_taxon.R <in.duckdb> <out.duckdb> [taxon.parquet]

# close the taxon coverage gap from the WoRMS REST API (run AFTER migrate_add_taxon.R
# and BEFORE migrate_add_eov.R — EOV membership is only as complete as `taxon`)
Rscript data-raw/migrate_fill_taxon_gaps.R <in.duckdb> <out.duckdb> [min_records]

# add the EOV layers (`eov` membership + precomputed `idx_h3_eov`) to a store
Rscript data-raw/migrate_add_eov.R <in.duckdb> <out.duckdb> [eov ...]

# add the coarse-parent `hex_prune` key + (res, hex_prune, cell_id) clustering to
# occ_h3/idx_h3 in an EXISTING store so the h3t server prunes each tile (no S3
# re-read, writes a new file; drops any interim lat/lng cols). rebuilds needn't
# run this — build_obis_h3_duckdb() bakes hex_prune natively.
Rscript data-raw/migrate_add_spatial_cluster.R <in.duckdb> <out.duckdb>
```

- CI: `.github/workflows/run_tests.yml` runs
  [`testthat::test_local()`](https://testthat.r-lib.org/reference/test_package.html)
  on every push/PR; `pkgdown.yaml` builds the site (allowed to fail
  without blocking).
- `inst/sql/*.sql` are **canonical, human-readable references** of what
  the R functions generate (`build_obis_h3.sql`, `tile_templates.sql`) —
  the R code is the source of truth; keep the SQL comments in sync when
  the R changes.
- Shipped `occ_*` datasets are regenerated by `data-raw/occ.R` from a
  full OBIS parquet export (gitignored, not in the repo); they are
  seeded/subsampled to keep the `.rda` files small.

## File map

- `R/analyze.R` —
  [`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md)
  (the indicator math reference).
- `R/h3.R` —
  [`make_hex_res()`](https://marinebon.org/obisindicators/reference/make_hex_res.md)
  (build an H3 hex grid `sf`, dateline-wrapped).
- `R/h3t.R` — the entire DuckDB build + tile-SQL/URL layer.
- `R/taxon.R` — WoRMS children resolution + the SPUE effort proxy.
- `R/taxon_gapfill.R` — WoRMS REST supplement closing the `taxon`
  coverage gap.
- `R/eov.R` — Essential Ocean Variables as multi-seed AphiaID subtrees.
- `R/visualize.R` —
  [`gmap_indicator()`](https://marinebon.org/obisindicators/reference/gmap_indicator.md)
  static ggplot maps.
- `R/data.R` — roxygen docs for the shipped `occ_*` datasets.
- roxygen `@concept` tags
  (`read`/`analyze`/`h3t`/`taxon`/`visualize`/`data`) drive the pkgdown
  reference index in `_pkgdown.yml` — tag new exported functions.

Downstream consumers of the SQL builders (they source `R/h3t.R` +
`R/taxon.R` directly, not the installed package):
`MarineSensitivity/apps/h3-db/app.R` (the Shiny explorer) and
`MarineSensitivity/api/plumber.R` (`GET /h3`, multi-format H3
summaries). Both must source **both** files — `obis_h3t_sql(aphiaid=)`
calls `.h3t_taxon_tree_cte()` from `R/taxon.R`.
