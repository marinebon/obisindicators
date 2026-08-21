# Summarize an obis_h3 store (tables, rows, totals)

The "Table 2" of a store: every table with its row count, plus the
headline totals a reader needs to size the data — records and species at
the base resolution, occupied cells per resolution, taxonomy rows, EOV
membership, and the file size.

## Usage

``` r
obis_store_stats(con)
```

## Arguments

- con:

  connection from
  [`obis_store_connect()`](https://marinebon.org/obisindicators/reference/obis_store_connect.md).

## Value

a list with `tables` (table, rows), `totals` (metric, value) and
`cells_by_res` (res, n_cells, area_km2).
