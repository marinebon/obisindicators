# Indicators per period (e.g. decade) and cell

Runs the year-filtered live tile SQL once per period and returns `n`,
`sp` and `es` per cell and period. Periods are
`[start, start + width - 1]`.

## Usage

``` r
calc_period_indicators(
  con,
  res = 2L,
  eov = NULL,
  aphiaid = NULL,
  taxon = NULL,
  starts = seq(1960L, 2020L, by = 10L),
  width = 10L,
  esn = 50L
)
```

## Arguments

- con:

  connection from
  [`obis_store_connect()`](https://marinebon.org/obisindicators/reference/obis_store_connect.md).

- res:

  H3 resolution (coarse, e.g. 2-3, is sensible: the denominator thins
  quickly when records are split by decade).

- eov:

  optional EOV name (one); see
  [`obis_eov_seeds()`](https://marinebon.org/obisindicators/reference/obis_eov_seeds.md).

- aphiaid:

  optional WoRMS AphiaID(s) — the subtree filter.

- taxon:

  optional named list of DwC rank values; see
  [`obis_h3t_sql()`](https://marinebon.org/obisindicators/reference/obis_h3t_sql.md).

- starts:

  period start years (default decades 1960-2020).

- width:

  period width in years (default 10).

- esn:

  expected sample size for ES(n); default 50.

## Value

data frame with `period`, `cell`, `n`, `sp`, `es`.
