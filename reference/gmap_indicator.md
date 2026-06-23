# Statically map indicators using ggplot

Statically map indicators using ggplot

## Usage

``` r
gmap_indicator(
  grid,
  column = "shannon",
  label = "Shannon index",
  trans = "identity",
 
    crs = "+proj=robin +lon_0=0 +x_0=0 +y_0=0 +ellps=WGS84 +datum=WGS84 +units=m +no_defs"
)
```

## Arguments

- grid:

  spatial features, e.g. hexagons, to plot; requires a geometry spatial
  column

- column:

  column name with indicator; default="shannon"

- label:

  label to show on legend

- trans:

  For continuous scales, the name of a transformation object or the
  object itself. Built-in transformations include "asn", "atanh",
  "boxcox", "date", "exp", "hms", "identity" (default), "log", "log10",
  "log1p", "log2", "logit", "modulus", "probability", "probit",
  "pseudo_log", "reciprocal", "reverse", "sqrt" and "time". See
  [`ggplot2::continuous_scale`](https://ggplot2.tidyverse.org/reference/continuous_scale.html)

- crs:

  coordinate reference system; see
  [`sf::st_crs()`](https://r-spatial.github.io/sf/reference/st_crs.html)

## Value

ggplot2 plot
