# obisindicators 0.2.0

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
