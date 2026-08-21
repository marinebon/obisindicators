# Indicators rolled up from H3 cells to places

Fills each polygon with H3 cells at `res`, sums species records over
those cells from `occ_h3` (optionally restricted to an EOV, an AphiaID
subtree, DwC rank values and/or a year range), and computes the
indicators per place with
[`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md).
Also reports the number of cells filled and the number with any record,
so sparse places are visible.

## Usage

``` r
calc_place_indicators(
  con,
  places,
  name_col = NULL,
  res = 7L,
  eov = NULL,
  aphiaid = NULL,
  taxon = NULL,
  years = NULL,
  esn = 50L
)
```

## Arguments

- con:

  connection from
  [`obis_store_connect()`](https://marinebon.org/obisindicators/reference/obis_store_connect.md).

- places:

  an `sf` of polygons (lon/lat, EPSG:4326).

- name_col:

  column naming each place; default the first non-geometry column.

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

## Value

data frame with `place`, `n_cells`, `n_cells_occupied`, and the
[`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md)
columns (`n`, `sp`, `shannon`, `simpson`, `es`, `hill_1`, `hill_2`,
`hill_inf`).
