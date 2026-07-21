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
