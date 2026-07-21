# Changelog

## obisindicators 0.4.2

- **Vignette H3 tile maps now actually render** (the `mapgl`/MapLibre
  chunks that 0.4.1 still left as code-only):
  - [`vignette("h3t")`](https://marinebon.org/obisindicators/articles/h3t.md)
    renders the interactive ES50 hexagon map;
    [`vignette("taxon_children")`](https://marinebon.org/obisindicators/articles/taxon_children.md)
    renders the Cetacea-records map and the SPUE map. These are
    client-side MapLibre widgets — tiles are fetched from the deployed
    `h3t` service in the reader’s browser, so they need no store/S3 at
    build time.
  - **New Remote dependency**: the maps require the h3t-antimeridian fix
    in `mapgl` (renders H3 hexagons that cross the dateline), pinned via
    `Remotes: mapgl=bbest/mapgl@fix/h3t-antimeridian`
    ([walkerke/mapgl#211](https://github.com/walkerke/mapgl/pull/211)).
    Switch to upstream `mapgl` once that PR merges.
  - Fixed a latent bug in the `h3t` map example — `interpolate(values=)`
    now has the same length as `stops=` (a 3-stop viridis ramp), which
    previously would have errored had the chunk been evaluated.
  - [`vignette("scaling")`](https://marinebon.org/obisindicators/articles/scaling.md)
    stays code-only: every chunk runs live benchmark queries against the
    deployed DuckDB store (no map widgets), which CI cannot reach.

## obisindicators 0.4.1

- **Vignettes now render their evaluable R chunks** on the pkgdown site
  instead of showing code-only:
  - [`vignette("h3")`](https://marinebon.org/obisindicators/articles/h3.md)
    runs the full h3-grid →
    [`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md)
    →
    [`gmap_indicator()`](https://marinebon.org/obisindicators/reference/gmap_indicator.md)
    pipeline on shipped `occ_1M` and renders the ES(50) map (only the
    `deckgl` install/demo stays code-only).
  - [`vignette("taxon_children")`](https://marinebon.org/obisindicators/articles/taxon_children.md)
    now renders the generated `WITH RECURSIVE` tile SQL and tile URLs
    from `obis_h3t_sql(aphiaid=)` /
    [`obis_spue_sql()`](https://marinebon.org/obisindicators/reference/obis_spue_sql.md)
    (pure builders, no store needed); only the DB-connection and `mapgl`
    widget chunks stay code-only.
  - [`vignette("h3t")`](https://marinebon.org/obisindicators/articles/h3t.md)
    suppresses package-load messages so the evaluated
    [`obis_h3t_sql()`](https://marinebon.org/obisindicators/reference/obis_h3t_sql.md)
    output is clean.
  - Chunks that genuinely require the deployed S3 / DuckDB store / `h3t`
    tile service
    ([`vignette("scaling")`](https://marinebon.org/obisindicators/articles/scaling.md),
    the build/deploy/map chunks) remain illustrative code, as they
    cannot run in CI.

## obisindicators 0.4.0

- **Automatic per-tile spatial pruning via `hex_prune`** (supersedes
  0.3.0’s client-side `{{bbox}}` placeholder). The tile bbox is fully
  determined by the `z/x/y` tile address, so the client no longer states
  it — the `h3t` server derives each tile’s covering coarse H3 cells
  from `z/x/y` and injects the prune itself:
  - [`build_obis_h3_duckdb()`](https://marinebon.org/obisindicators/reference/build_obis_h3_duckdb.md)
    now materializes a coarse H3-parent column
    `hex_prune = h3_cell_to_parent(cell_id, LEAST(res, H3T_PRUNE_RES))`
    (res 3) on `occ_h3` and `idx_h3` and clusters both by
    `(res, hex_prune, cell_id)`. This replaces the interim `lat`/`lng`
    clustering — pruning on the H3 index is 2D (tighter than a latitude
    band), needs no extra float columns, and the covering ids are
    canonical H3 (they match across the R build and the server with no
    version drift). **Store schema change** — rebuild, or migrate with
    `data-raw/migrate_add_spatial_cluster.R` (drops `lat`/`lng`, adds
    `hex_prune`).
  - [`obis_h3t_sql()`](https://marinebon.org/obisindicators/reference/obis_h3t_sql.md)
    /
    [`obis_spue_sql()`](https://marinebon.org/obisindicators/reference/obis_spue_sql.md)
    now emit **plain per-resolution SELECTs** — the `bbox_placeholder`
    argument is **removed**. The server (`MarineSensitivity/server/h3t`,
    `CalCOFI/api-h3t-py`) rewrites the query to add
    `hex_prune IN (<covering cells>)` to any scan of a table carrying
    that column; stores without it are untouched.
  - The math is unchanged and still pinned to
    [`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md)
    /
    [`calc_spue()`](https://marinebon.org/obisindicators/reference/calc_spue.md);
    `test-h3t-prune.R` asserts the prune is **result-preserving** (a
    `hex_prune`-pruned scan + the server’s outer centroid filter returns
    exactly the same cells and values as the unpruned scan).

## obisindicators 0.3.0

- **Spatial (bbox) tile pruning** *(interim — the `{{bbox}}` placeholder
  and `lat`/`lng` clustering here were replaced by the `hex_prune`
  approach in 0.4.0; kept for history)*. Live `occ_h3` / `idx_h3` tile
  maps were pruned per tile instead of aggregating the whole globe for
  every tile:
  - [`build_obis_h3_duckdb()`](https://marinebon.org/obisindicators/reference/build_obis_h3_duckdb.md)
    materialized cell-centroid `lat`/`lng` columns on `occ_h3` and
    `idx_h3` and clustered both by `(res, lat, lng)`.
  - [`obis_h3t_sql()`](https://marinebon.org/obisindicators/reference/obis_h3t_sql.md)
    /
    [`obis_spue_sql()`](https://marinebon.org/obisindicators/reference/obis_spue_sql.md)
    gained a `bbox_placeholder` argument (default `"{{bbox}}"`) that the
    `h3t` service substituted per tile with a `lat`/`lng` predicate.
  - The math stayed pinned to
    [`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md)
    /
    [`calc_spue()`](https://marinebon.org/obisindicators/reference/calc_spue.md);
    the prune was asserted result-preserving.

## obisindicators 0.2.0

- Added **WoRMS taxonomy children resolution** and an **effort proxy
  (SPUE)** so OBIS can be filtered by any WoRMS AphiaID at any rank from
  the local snapshot (see
  [`vignette("taxon_children")`](https://marinebon.org/obisindicators/articles/taxon_children.md),
  [`vignette("scaling")`](https://marinebon.org/obisindicators/articles/scaling.md)):
  - [`obis_taxon_children()`](https://marinebon.org/obisindicators/reference/obis_taxon_children.md)
    /
    [`obis_taxon_subtree_sql()`](https://marinebon.org/obisindicators/reference/obis_taxon_subtree_sql.md)
    recursively walk a `taxon` table (baked into the store;
    `data-raw/build_taxon_parquet.R` + `data-raw/migrate_add_taxon.R`)
    to return every descendant taxon.
  - `obis_h3t_sql(aphiaid=)` serves arbitrary-rank children maps by
    filtering `occ_h3.aphiaid` to the resolved subtree via a
    `WITH RECURSIVE` CTE.
  - [`calc_spue()`](https://marinebon.org/obisindicators/reference/calc_spue.md)
    (R reference) +
    [`obis_spue_sql()`](https://marinebon.org/obisindicators/reference/obis_spue_sql.md)
    compute the presence-only effort proxy
    `records(target subtree) / records(effort subtree)` per cell, pinned
    by `test-spue-parity.R`.
- Added an **H3 tiling (h3t)** workflow to serve indicators as on-demand
  H3 hexagon map tiles (see
  [`vignette("h3t")`](https://marinebon.org/obisindicators/articles/h3t.md)):
  - [`build_obis_h3_duckdb()`](https://marinebon.org/obisindicators/reference/build_obis_h3_duckdb.md)
    builds an authoritative DuckDB store from OBIS open-data parquet — a
    precomputed all-taxa indicator layer (`idx_h3`, res 1–7) plus a
    species-level store (`occ_h3`, tiers 3/5/7) for on-the-fly
    taxon/year-filtered queries. The ES50/Shannon/Simpson/richness math
    is the SQL translation of
    [`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md),
    pinned by a new parity test.
  - [`obis_h3t_sql()`](https://marinebon.org/obisindicators/reference/obis_h3t_sql.md)
    /
    [`obis_h3t_url()`](https://marinebon.org/obisindicators/reference/obis_h3t_url.md)
    compose the validated read-only `SELECT` and the base64-encoded tile
    URL for the `h3t` service (`MarineSensitivity/server/h3t`) and
    [`mapgl::add_h3t_source()`](https://walker-data.com/mapgl/reference/add_h3t_source.html).
  - canonical SQL in `inst/sql/`; server build driver in
    `data-raw/build_obis_h3_duckdb.R`.

## obisindicators 0.0.2

- Renamed functions for consistency:
  - `calc_es50()` -\>
    [`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md)
  - `gmap_metric()` -\>
    [`gmap_indicator()`](https://marinebon.org/obisindicators/reference/gmap_indicator.md)
- Fixed
  [`gmap_indicator()`](https://marinebon.org/obisindicators/reference/gmap_indicator.md)
  to use default Robinson projection.
- Updated vignettes with name changes and use of “indicators” over
  “metrics”.
- Supplemented documentation for
  [`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md)
  with expected input and output columns to data frame.
- Added documentation for `occ_fk` and `occ_1960s` to `occ_2010s`
- Made generation of occ\_\* datasets more reproducible with
  [`set.seed()`](https://rdrr.io/r/base/Random.html) and sampled
  versions of dataset to minimize file size on Github in
  `data-raw/occ.R`.

## obisindicators 0.0.1

- Added a `NEWS.md` file to track changes to the package.
