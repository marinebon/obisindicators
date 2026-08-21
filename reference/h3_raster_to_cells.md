# Aggregate a raster (e.g. an SDM) to H3 cells

Two strategies: `"centers"` assigns every non-NA raster cell centre to
an H3 cell at `res` and averages (right when hexagons are larger than
raster cells); `"centroids"` samples the raster at each requested
hexagon's centroid (right when hexagons are smaller). `"auto"` picks
centres when the mean hexagon area is at least `ratio` times the raster
cell area.

## Usage

``` r
h3_raster_to_cells(
  r,
  res,
  cells = NULL,
  method = c("auto", "centers", "centroids"),
  ratio = 3
)
```

## Arguments

- r:

  a
  [`terra::SpatRaster`](https://rspatial.github.io/terra/reference/SpatRaster-class.html)
  (single layer, lon/lat).

- res:

  H3 resolution.

- cells:

  optional hex strings to restrict/sample to (required for
  `"centroids"`).

- method:

  `"auto"`, `"centers"` or `"centroids"`.

- ratio:

  hexagon-to-raster-cell area ratio above which `"auto"` uses centres
  (default 3).

## Value

data frame with `cell`, `value` (mean), `n_px` (raster cells averaged; 1
for centroid sampling).
