# Make hexagon feature

TODO: + sf feature or extent to minimize

## Usage

``` r
make_hex_res(hex_res = 2)
```

## Arguments

- hex_res:

  resolution of H3 hexagons; see [Table of Cell Areas for H3 Resolutions
  \| H3](https://h3geo.org/docs/core-library/restable/)

## Value

spatial feature `sf` object

## Examples

``` r
hexes <- make_hex_res(0)
```
