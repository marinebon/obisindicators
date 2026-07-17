# obisindicators 0.3.0

* **Spatial (bbox) tile pruning** — live `occ_h3` / `idx_h3` tile maps (any-rank
  `aphiaid` children, SPUE, finer/multi-value/year filters, and the all-taxa
  layer) are now pruned per tile instead of aggregating the whole globe for
  every tile, so they stay fast when zoomed in to fine H3 resolutions:
  - `build_obis_h3_duckdb()` now materializes cell-centroid `lat`/`lng` columns
    on `occ_h3` and `idx_h3` and clusters both **spatially** by `(res, lat, lng)`
    (superseding `occ_h3`'s old `(res, taxonomy)` clustering). Zonemaps then
    prune row groups to a tile's extent. **Store schema change** — rebuild, or
    migrate an existing store with `data-raw/migrate_add_spatial_cluster.R`.
  - `obis_h3t_sql()` / `obis_spue_sql()` gain a `bbox_placeholder` argument
    (default `"{{bbox}}"`, spliced into the scan `WHERE`) that the `h3t` tile
    service substitutes per tile with a `lat`/`lng` predicate. Pass `""` to
    disable for direct execution (e.g. the `/h3` API and stats queries).
  - The math is unchanged and still pinned to `calc_indicators()` /
    `calc_spue()`; a new `test-h3t-bbox.R` asserts the prune is
    **result-preserving** (a bbox-pruned scan + the server's outer centroid
    filter returns exactly the same cells and values as the unpruned scan).

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
