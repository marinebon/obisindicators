# H3 cells covering each place polygon

H3 cells covering each place polygon

## Usage

``` r
place_cells(places, name_col = NULL, res = 7L)
```

## Arguments

- places:

  an `sf` of polygons (lon/lat, EPSG:4326).

- name_col:

  column naming each place; default the first non-geometry column.

- res:

  H3 resolution to fill at (default 7, the store's base).

## Value

data frame with `place`, `cell` (hex string).
