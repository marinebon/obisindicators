# Add an exact place collection to an existing `obis-h3` release

[`obis_place_exact_write()`](https://marinebon.org/obisindicators/reference/obis_place_exact_write.md)
puts `place_exact/coll=<coll>/` into a release directory; this registers
it the way
[`obis_h3_export_parquet()`](https://marinebon.org/obisindicators/reference/obis_h3_export_parquet.md)
does for a `place_exact` collection exported in the same run:
`release.json` gets the `layers$place_exact` entry (the collection from
its `meta.json`, plus the layer's `rows`, `files` and `bytes` over every
collection on disk), and, with `manifest = TRUE`, `files.parquet` has
its `place_exact` rows replaced by one row per file on disk and
`files$n_files` in `release.json` is updated. The layer's `template`,
`columns` and `note` are kept when `release.json` already has them.
Nothing else in the release is touched (`stats.parquet`, the other
layers' rows, `collection.json`), and running it again for the same
`coll` gives the same entries.

## Usage

``` r
obis_h3_add_place_exact(
  release_dir,
  coll,
  source = NULL,
  manifest = TRUE,
  compression = "zstd"
)
```

## Arguments

- release_dir:

  the release directory (holding `release.json`, `files.parquet` and
  `place_exact/coll=<coll>/{indicators,years}.parquet`, `meta.json`).

- coll:

  the collection slug already written under `place_exact/`.

- source:

  optional text recorded as the collection's `source` (where the
  polygons came from); default: the existing entry's, else omitted.

- manifest:

  also update `files.parquet` (default `TRUE`).

- compression:

  Parquet compression of the rewritten `files.parquet`.

## Value

invisibly, the paths of the files rewritten (`release.json`, and
`files.parquet` with `manifest = TRUE`).

## Details

Use it to add a collection after a release was built (for example the
gazetteer `places` sanctuaries, computed with
`data-raw/run_place_exact.R`), on a staging copy of the release:
`release_dir` must hold `release.json`, and `files.parquet` when
`manifest = TRUE`, plus every collection the release already lists (a
collection listed in `release.json` but missing on disk is kept in
`collections` with a warning, and not counted in `rows`, `files`,
`bytes`).
