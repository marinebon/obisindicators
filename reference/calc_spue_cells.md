# SPUE effort proxy per cell at one resolution

Runs
[`obis_spue_sql()`](https://marinebon.org/obisindicators/reference/obis_spue_sql.md)
at a fixed resolution and returns, per effort cell, the target and
effort record counts and their ratio.

## Usage

``` r
calc_spue_cells(con, num_aphiaid, den_aphiaid, res)
```

## Arguments

- con:

  connection from
  [`obis_store_connect()`](https://marinebon.org/obisindicators/reference/obis_store_connect.md).

- num_aphiaid:

  target-taxon AphiaID(s) (numerator subtree).

- den_aphiaid:

  effort-taxon AphiaID(s) (denominator subtree); typically a
  higher-order taxon such as the target's parent class.

- res:

  H3 resolution (1-7).

## Value

data frame with `cell`, `spue`, `effort` (denominator records), `target`
(numerator records).
