# Compare the SPUE effort proxy with modeled suitability

Joins per-cell SPUE
([`calc_spue_cells()`](https://marinebon.org/obisindicators/reference/calc_spue_cells.md))
with a model surface aggregated to the same cells
([`h3_raster_to_cells()`](https://marinebon.org/obisindicators/reference/h3_raster_to_cells.md)),
keeps cells with at least `min_effort` effort records, and reports
Spearman's rank correlation plus a calibration table: mean model value
by SPUE bin (bin 0 = target never recorded despite effort; bins
1..`n_bins` = quantile bins of positive SPUE).

## Usage

``` r
compare_spue_sdm(spue, sdm, min_effort = 30L, n_bins = 5L)
```

## Arguments

- spue:

  output of
  [`calc_spue_cells()`](https://marinebon.org/obisindicators/reference/calc_spue_cells.md).

- sdm:

  output of
  [`h3_raster_to_cells()`](https://marinebon.org/obisindicators/reference/h3_raster_to_cells.md)
  (`cell`, `value`).

- min_effort:

  effort floor (default 30 records).

- n_bins:

  number of positive-SPUE quantile bins (default 5).

## Value

list with `stats` (n_cells, rho, p_value, frac_present), `calib` (bin,
n_cells, spue_mean, sdm_mean, sdm_sd) and `data` (the joined cells).
