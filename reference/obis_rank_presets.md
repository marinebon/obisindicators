# Default taxon-group presets for the rank-vs-subtree comparison

The h3-db app's taxon groups, each as the DwC rank column a user would
naively filter on and the WoRMS AphiaID that seeds the subtree. Two of
them (Actinopterygii, Anthozoa) are filed at a different rank by
WoRMS/OBIS and match nothing by rank column — the point of
[`calc_rank_vs_subtree()`](https://marinebon.org/obisindicators/reference/calc_rank_vs_subtree.md).

## Usage

``` r
obis_rank_presets()
```

## Value

data frame with `label`, `rank`, `name`, `aphiaid`.
