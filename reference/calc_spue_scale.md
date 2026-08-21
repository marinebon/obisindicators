# Scale curves for the SPUE effort proxy

How the effort denominator thins with resolution: per resolution, the
number of effort cells, the median effort count, the fraction of effort
cells below each reliability floor, and the fraction of effort cells
where the target was seen at all.

## Usage

``` r
calc_spue_scale(
  con,
  num_aphiaid,
  den_aphiaid,
  res = 1:7,
  floors = c(10L, 30L, 100L),
  group = NULL
)
```

## Arguments

- con:

  connection from
  [`obis_store_connect()`](https://marinebon.org/obisindicators/reference/obis_store_connect.md).

- num_aphiaid, den_aphiaid:

  target / effort AphiaID(s); see
  [`obis_spue_sql()`](https://marinebon.org/obisindicators/reference/obis_spue_sql.md).

- res:

  resolutions (default 1:7).

- floors:

  effort-count floors (default 10, 30, 100).

- group:

  optional label carried in a `group` column.

## Value

data frame, one row per resolution.
