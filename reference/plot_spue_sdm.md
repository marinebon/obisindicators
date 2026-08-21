# Plot SPUE-vs-model calibration

Mean modeled value (with ±1 SD) per SPUE bin from
[`compare_spue_sdm()`](https://marinebon.org/obisindicators/reference/compare_spue_sdm.md).

## Usage

``` r
plot_spue_sdm(cmp, ylab = "modeled suitability")
```

## Arguments

- cmp:

  output of
  [`compare_spue_sdm()`](https://marinebon.org/obisindicators/reference/compare_spue_sdm.md).

- ylab:

  y-axis label (default "modeled suitability").

## Value

ggplot2 plot
