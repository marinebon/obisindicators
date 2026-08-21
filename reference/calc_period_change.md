# Change in an indicator between two periods, where both are reliable

Joins the cells of two periods from
[`calc_period_indicators()`](https://marinebon.org/obisindicators/reference/calc_period_indicators.md)
and keeps those with `n >= esn` in both, so ES(n) is defined on each
side. Also reports how coverage changed (cells reliable only in one
period).

## Usage

``` r
calc_period_change(df, from, to, esn = 50L, indicator = c("es", "sp"))
```

## Arguments

- df:

  output of
  [`calc_period_indicators()`](https://marinebon.org/obisindicators/reference/calc_period_indicators.md).

- from, to:

  the two `period` values to compare.

- esn:

  reliability floor on `n` (default 50, the ES(50) floor).

- indicator:

  which indicator to difference (`"es"` or `"sp"`).

## Value

list with `cells` (cell, value_from, value_to, delta, pct, n_from, n_to)
and `coverage` (counts of cells reliable in both / only from / only to).
