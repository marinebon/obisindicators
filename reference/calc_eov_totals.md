# Records, species and cells per Essential Ocean Variable

Totals at the base resolution for each EOV, via the baked `eov`
membership table when present, else by resolving each EOV's seed subtree
live.

## Usage

``` r
calc_eov_totals(con, eov = NULL, res = H3T_RES_BASE)
```

## Arguments

- con:

  connection from
  [`obis_store_connect()`](https://marinebon.org/obisindicators/reference/obis_store_connect.md).

- eov:

  EOV name(s); default all.

- res:

  resolution tier of `occ_h3` to count on (default 7).

## Value

data frame with `eov`, `label`, `records`, `species`, `cells`,
`pct_records` (share of all records at that tier).
