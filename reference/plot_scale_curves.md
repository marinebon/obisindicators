# Plot scale curves

Small multiples of the summaries from
[`calc_scale_curves()`](https://marinebon.org/obisindicators/reference/calc_scale_curves.md)
(or
[`calc_spue_scale()`](https://marinebon.org/obisindicators/reference/calc_spue_scale.md))
against H3 resolution, one line per `group` when present. Metrics named
in `log_y` are drawn as `log10(metric)`.

## Usage

``` r
plot_scale_curves(
  df,
  metrics = c("n_cells", "median_n", "frac_eligible", "median_es"),
  log_y = c("n_cells", "median_n")
)
```

## Arguments

- df:

  output of
  [`calc_scale_curves()`](https://marinebon.org/obisindicators/reference/calc_scale_curves.md)
  /
  [`calc_spue_scale()`](https://marinebon.org/obisindicators/reference/calc_spue_scale.md),
  possibly several bound together with a `group` column.

- metrics:

  columns to plot (default the four headline curves).

- log_y:

  metrics to draw on a log10 scale.

## Value

ggplot2 plot
