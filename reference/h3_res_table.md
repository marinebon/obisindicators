# H3 resolution table

Average hexagon area (km²) and edge length (km) per H3 resolution, from
the [H3 resolution table](https://h3geo.org/docs/core-library/restable).

## Usage

``` r
h3_res_table(res = NULL)
```

## Arguments

- res:

  optional resolution(s) to subset to.

## Value

data frame with `res`, `area_km2`, `edge_km`.

## Examples

``` r
h3_res_table(1:7)
#>   res   area_km2 edge_km
#> 1   1 609788.442 483.057
#> 2   2  86801.780 182.513
#> 3   3  12393.435  68.979
#> 4   4   1770.348  26.072
#> 5   5    252.904   9.854
#> 6   6     36.129   3.725
#> 7   7      5.161   1.406
```
