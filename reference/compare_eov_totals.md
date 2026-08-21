# Compare EOV totals between two stores (e.g. before/after taxonomy gap-fill)

Compare EOV totals between two stores (e.g. before/after taxonomy
gap-fill)

## Usage

``` r
compare_eov_totals(before, after)
```

## Arguments

- before, after:

  outputs of
  [`calc_eov_totals()`](https://marinebon.org/obisindicators/reference/calc_eov_totals.md)
  from the two stores.

## Value

data frame with `eov`, `label`, `records_before`, `records_after`,
`records_delta`, `records_pct`, `species_before`, `species_after`,
`cells_before`, `cells_after`.
