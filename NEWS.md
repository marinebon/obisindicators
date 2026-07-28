# obisindicators 0.5.0

* **Essential Ocean Variables (EOVs)** — new `R/eov.R` maps the GOOS/IOOS
  biology & ecosystems EOVs onto the H3 store. The
  [IOOS Marine Life Data Network](https://github.com/ioos/marine_life_data_network/tree/main/eov_taxonomy)
  defines each EOV as a handful of root WoRMS AphiaIDs (33 seeds across 7 EOVs:
  fish, hardCorals, mangroves, marineMammals, seabirds, seagrasses, seaTurtles),
  which is exactly a multi-seed version of the existing subtree walk.
  - `obis_eov_seeds()` / `obis_eov_aphiaid()` — the EOV definitions.
  - `obis_eov_sql()` — tile SQL for an EOV, routing to a precomputed layer when
    it can and to the live AphiaID-subtree path when it must (year filters,
    several EOVs at once, or a store without the layer baked).
  - `obis_eov_bake()` — adds `eov` (membership) and `idx_h3_eov` (precomputed
    indicators, res 1-7) to a store; now also a step in
    `build_obis_h3_duckdb()`, skipped with a note when `taxon` is absent.
  - New driver `data-raw/migrate_add_eov.R`.

* **WoRMS gap-fill** — new `R/taxon_gapfill.R` closes a silent coverage hole.
  The bulk WoRMS `taxon.txt` download is not a complete cover of the AphiaIDs
  OBIS carries: on the 2026-07 global store 12,021 of 167,190 distinct
  `occ_h3.aphiaid` values (~7%, covering 8.3M of 121.9M records) were absent
  from `taxon`, so they were invisible to every `aphiaid` / EOV / SPUE query.
  - `obis_taxon_orphans()` — report the gap.
  - `wm_aphia_records()` — batched, parallel WoRMS REST lookups
    (`AphiaRecordsByAphiaIDs`, 50 ids/request), the per-id supplement to the
    bulk download.
  - `obis_taxon_fill_gaps()` — fills orphans **and** iterates to transitive
    closure, because inserting an orphan whose ancestors are still missing
    leaves it disconnected from any seed above it. Warns and reports
    `closed = FALSE` rather than implying a whole tree if `max_rounds` is hit.
  - New driver `data-raw/migrate_fill_taxon_gaps.R`.
  - Adds `httr2` to Suggests.

* **Two taxon-group presets in the h3-db app returned zero records** (fixed in
  `MarineSensitivity/apps/h3-db`, noted here because it motivated the EOV
  design): filtering the DwC `class` column cannot match when WoRMS files the
  name at another rank — `class='Actinopterygii'` (a Gigaclass; OBIS's class is
  `Teleostei`, 44.2M records) and `class='Anthozoa'` (a Subphylum; OBIS uses
  `Hexacorallia`/`Octocorallia`) both matched nothing. AphiaID subtree walking
  is rank-agnostic and immune to this.

* Parity: `.h3t_idx_eov_sql()` is a fifth copy of the `calc_indicators()` ES(n)
  term and is pinned cell-for-cell by the new `tests/testthat/test-eov-parity.R`.

# obisindicators 0.4.2

* **Vignette H3 tile maps now actually render** (the `mapgl`/MapLibre chunks that
  0.4.1 still left as code-only):
  - `vignette("h3t")` renders the interactive ES50 hexagon map; `vignette("taxon_children")`
    renders the Cetacea-records map and the SPUE map. These are client-side
    MapLibre widgets — tiles are fetched from the deployed `h3t` service in the
    reader's browser, so they need no store/S3 at build time.
  - **New Remote dependency**: the maps require the h3t-antimeridian fix in
    `mapgl` (renders H3 hexagons that cross the dateline), pinned via
    `Remotes: mapgl=bbest/mapgl@fix/h3t-antimeridian`
    ([walkerke/mapgl#211](https://github.com/walkerke/mapgl/pull/211)). Switch to
    upstream `mapgl` once that PR merges.
  - Fixed a latent bug in the `h3t` map example — `interpolate(values=)` now has
    the same length as `stops=` (a 3-stop viridis ramp), which previously would
    have errored had the chunk been evaluated.
  - `vignette("scaling")` stays code-only: every chunk runs live benchmark
    queries against the deployed DuckDB store (no map widgets), which CI cannot
    reach.

# obisindicators 0.4.1

* **Vignettes now render their evaluable R chunks** on the pkgdown site instead
  of showing code-only:
  - `vignette("h3")` runs the full h3-grid → `calc_indicators()` → `gmap_indicator()`
    pipeline on shipped `occ_1M` and renders the ES(50) map (only the `deckgl`
    install/demo stays code-only).
  - `vignette("taxon_children")` now renders the generated `WITH RECURSIVE`
    tile SQL and tile URLs from `obis_h3t_sql(aphiaid=)` / `obis_spue_sql()`
    (pure builders, no store needed); only the DB-connection and `mapgl`
    widget chunks stay code-only.
  - `vignette("h3t")` suppresses package-load messages so the evaluated
    `obis_h3t_sql()` output is clean.
  - Chunks that genuinely require the deployed S3 / DuckDB store / `h3t` tile
    service (`vignette("scaling")`, the build/deploy/map chunks) remain
    illustrative code, as they cannot run in CI.

# obisindicators 0.4.0

* **Automatic per-tile spatial pruning via `hex_prune`** (supersedes 0.3.0's
  client-side `{{bbox}}` placeholder). The tile bbox is fully determined by the
  `z/x/y` tile address, so the client no longer states it — the `h3t` server
  derives each tile's covering coarse H3 cells from `z/x/y` and injects the
  prune itself:
  - `build_obis_h3_duckdb()` now materializes a coarse H3-parent column
    `hex_prune = h3_cell_to_parent(cell_id, LEAST(res, H3T_PRUNE_RES))` (res 3)
    on `occ_h3` and `idx_h3` and clusters both by `(res, hex_prune, cell_id)`.
    This replaces the interim `lat`/`lng` clustering — pruning on the H3 index is
    2D (tighter than a latitude band), needs no extra float columns, and the
    covering ids are canonical H3 (they match across the R build and the server
    with no version drift). **Store schema change** — rebuild, or migrate with
    `data-raw/migrate_add_spatial_cluster.R` (drops `lat`/`lng`, adds `hex_prune`).
  - `obis_h3t_sql()` / `obis_spue_sql()` now emit **plain per-resolution
    SELECTs** — the `bbox_placeholder` argument is **removed**. The server
    (`MarineSensitivity/server/h3t`, `CalCOFI/api-h3t-py`) rewrites the query to
    add `hex_prune IN (<covering cells>)` to any scan of a table carrying that
    column; stores without it are untouched.
  - The math is unchanged and still pinned to `calc_indicators()` /
    `calc_spue()`; `test-h3t-prune.R` asserts the prune is **result-preserving**
    (a `hex_prune`-pruned scan + the server's outer centroid filter returns
    exactly the same cells and values as the unpruned scan).

# obisindicators 0.3.0

* **Spatial (bbox) tile pruning** *(interim — the `{{bbox}}` placeholder and
  `lat`/`lng` clustering here were replaced by the `hex_prune` approach in
  0.4.0; kept for history)*. Live `occ_h3` / `idx_h3` tile maps were pruned per
  tile instead of aggregating the whole globe for every tile:
  - `build_obis_h3_duckdb()` materialized cell-centroid `lat`/`lng` columns on
    `occ_h3` and `idx_h3` and clustered both by `(res, lat, lng)`.
  - `obis_h3t_sql()` / `obis_spue_sql()` gained a `bbox_placeholder` argument
    (default `"{{bbox}}"`) that the `h3t` service substituted per tile with a
    `lat`/`lng` predicate.
  - The math stayed pinned to `calc_indicators()` / `calc_spue()`; the prune was
    asserted result-preserving.

# obisindicators 0.2.0

* Added **WoRMS taxonomy children resolution** and an **effort proxy (SPUE)** so
  OBIS can be filtered by any WoRMS AphiaID at any rank from the local snapshot
  (see `vignette("taxon_children")`, `vignette("scaling")`):
  - `obis_taxon_children()` / `obis_taxon_subtree_sql()` recursively walk a
    `taxon` table (baked into the store; `data-raw/build_taxon_parquet.R` +
    `data-raw/migrate_add_taxon.R`) to return every descendant taxon.
  - `obis_h3t_sql(aphiaid=)` serves arbitrary-rank children maps by filtering
    `occ_h3.aphiaid` to the resolved subtree via a `WITH RECURSIVE` CTE.
  - `calc_spue()` (R reference) + `obis_spue_sql()` compute the presence-only
    effort proxy `records(target subtree) / records(effort subtree)` per cell,
    pinned by `test-spue-parity.R`.

* Added an **H3 tiling (h3t)** workflow to serve indicators as on-demand H3
  hexagon map tiles (see `vignette("h3t")`):
  - `build_obis_h3_duckdb()` builds an authoritative DuckDB store from OBIS
    open-data parquet — a precomputed all-taxa indicator layer (`idx_h3`, res
    1–7) plus a species-level store (`occ_h3`, tiers 3/5/7) for on-the-fly
    taxon/year-filtered queries. The ES50/Shannon/Simpson/richness math is the
    SQL translation of `calc_indicators()`, pinned by a new parity test.
  - `obis_h3t_sql()` / `obis_h3t_url()` compose the validated read-only `SELECT`
    and the base64-encoded tile URL for the `h3t` service
    (`MarineSensitivity/server/h3t`) and `mapgl::add_h3t_source()`.
  - canonical SQL in `inst/sql/`; server build driver in
    `data-raw/build_obis_h3_duckdb.R`.

# obisindicators 0.0.2

* Renamed functions for consistency:
  - `calc_es50()` -> `calc_indicators()`
  - `gmap_metric()` -> `gmap_indicator()`
* Fixed `gmap_indicator()` to use default Robinson projection.
* Updated vignettes with name changes and use of "indicators" over "metrics".
* Supplemented documentation for `calc_indicators()` with expected input and output columns to data frame.
* Added documentation for `occ_fk` and `occ_1960s` to `occ_2010s`
* Made generation of occ_* datasets more reproducible with `set.seed()` and sampled versions of dataset to minimize file size on Github in `data-raw/occ.R`.

# obisindicators 0.0.1

* Added a `NEWS.md` file to track changes to the package.
