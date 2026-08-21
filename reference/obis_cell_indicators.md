# Per-cell indicators for a filter at one resolution

Returns every indicator the tile builders expose — record count `n`,
richness `sp`, `shannon`, ES(n) `es` — for one filter (all taxa, an EOV,
an AphiaID subtree, or DwC rank values) at one H3 resolution, as a data
frame keyed on the hex string. Reads a precomputed layer (`idx_h3`,
`idx_h3_eov`) in one query when the filter allows, otherwise runs the
live tile SQL once per indicator and joins. No new indicator math lives
here: everything comes from
[`obis_h3t_sql()`](https://marinebon.org/obisindicators/reference/obis_h3t_sql.md)
/
[`obis_eov_sql()`](https://marinebon.org/obisindicators/reference/obis_eov_sql.md),
which are pinned to
[`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md)
by the package tests.

## Usage

``` r
obis_cell_indicators(
  con,
  res,
  eov = NULL,
  aphiaid = NULL,
  taxon = NULL,
  years = NULL,
  esn = 50L,
  live = NULL
)
```

## Arguments

- con:

  connection from
  [`obis_store_connect()`](https://marinebon.org/obisindicators/reference/obis_store_connect.md).

- res:

  H3 resolution (1-7).

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

- live:

  force the live `occ_h3` path even when a precomputed layer exists
  (default NULL = use the precomputed layer when possible).

## Value

data frame with `cell`, `n`, `sp`, `shannon`, `es` (and `simpson` when
read from a precomputed layer).
