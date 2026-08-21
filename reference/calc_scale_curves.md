# Scale curves: indicator summaries across H3 resolutions

For one filter (all taxa, an EOV, an AphiaID subtree or DwC rank
values), summarizes the per-cell indicators at each resolution: occupied
cells, records, the distribution of records per cell, the fraction of
cells where ES(n) is defined (`n >= esn`), and medians of ES(n) and
richness among those. `n_cells_all` is the number of cells occupied by
*any* taxon at that resolution (from `idx_h3`), so `frac_cells_all`
reads as the filter's footprint relative to all sampling.

## Usage

``` r
calc_scale_curves(
  con,
  res = 1:7,
  eov = NULL,
  aphiaid = NULL,
  taxon = NULL,
  years = NULL,
  esn = 50L,
  floors = c(10L, 30L, 100L),
  group = NULL
)
```

## Arguments

- con:

  connection from
  [`obis_store_connect()`](https://marinebon.org/obisindicators/reference/obis_store_connect.md).

- res:

  resolutions to evaluate (default 1:7).

- eov:

  optional EOV name (one); see
  [`obis_eov_seeds()`](https://marinebon.org/obisindicators/reference/obis_eov_seeds.md).

- aphiaid:

  optional WoRMS AphiaID(s) — the subtree filter.

- taxon:

  optional named list of DwC rank values; see
  [`obis_h3t_sql()`](https://marinebon.org/obisindicators/reference/obis_h3t_sql.md).

- years:

  optional `c(min, max)` year range.

- esn:

  expected sample size for ES(n); default 50.

- floors:

  record-count floors for the reliability columns `frac_n_ge_<floor>`
  (default 10, 30, 100).

- group:

  optional label carried in a `group` column (handy when binding curves
  for several EOVs).

## Value

data frame, one row per resolution.
