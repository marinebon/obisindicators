# H3 cells (hex strings) to `sf` polygons

Vectorized boundary lookup with dateline wrapping, the same treatment as
[`make_hex_res()`](https://marinebon.org/obisindicators/reference/make_hex_res.md)
but for an arbitrary set of cells (e.g. the `cell` column returned by
[`obis_cell_indicators()`](https://marinebon.org/obisindicators/reference/obis_cell_indicators.md)).

## Usage

``` r
hex_sf(cells, dl_offset = 60)
```

## Arguments

- cells:

  character vector of H3 indexes.

- dl_offset:

  `DATELINEOFFSET` passed to
  [`sf::st_wrap_dateline()`](https://r-spatial.github.io/sf/reference/st_transform.html);
  default 60 (enough for res \>= 1).

## Value

`sf` with columns `cell` and `geometry`, one row per input cell.
