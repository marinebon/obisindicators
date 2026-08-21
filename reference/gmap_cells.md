# Map a per-cell table of indicators

Joins a data frame keyed on `cell` (hex string) to hexagon polygons and
draws it with
[`gmap_indicator()`](https://marinebon.org/obisindicators/reference/gmap_indicator.md).

## Usage

``` r
gmap_cells(
  df,
  column = "es",
  label = column,
  trans = "identity",
  mask = NULL,
  ...
)
```

## Arguments

- df:

  data frame with a `cell` column (e.g. from
  [`obis_cell_indicators()`](https://marinebon.org/obisindicators/reference/obis_cell_indicators.md),
  [`calc_spue_cells()`](https://marinebon.org/obisindicators/reference/calc_spue_cells.md)).

- column:

  column to fill by (default `"es"`).

- label:

  legend label (default `column`).

- trans:

  scale transformation (see
  [`gmap_indicator()`](https://marinebon.org/obisindicators/reference/gmap_indicator.md)).

- mask:

  optional logical vector (same length as `df`) — cells where `FALSE`
  are drawn with `NA` fill (e.g. `df$n >= 50` to mask unreliable
  ES(50)).

- ...:

  passed to
  [`gmap_indicator()`](https://marinebon.org/obisindicators/reference/gmap_indicator.md)
  (`crs`, `bbox`).

## Value

ggplot2 plot
