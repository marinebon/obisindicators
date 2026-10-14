# H3 membership files of a gazetteer collection

Resolves a polygon collection of the Ocean Metrics gazetteer to the
`membership.parquet` files of one H3 resolution, read off the
collection's `h3/membership.json`. Each file has the columns `place_id`
(VARCHAR), `h3` (lowercase hex string) and `share` (the fraction of the
cell's area inside the place; the gazetteer keeps a cell when it is at
least `min_share`, 1%, or when the cell holds at least 1% of the place).
A cell may belong to several places. Resolutions 1-5 are one file each,
the finer ones one file per parent cell.

## Usage

``` r
obis_place_membership(collection, res = 7L, base = PLACE_GAZETTEER_BASE)
```

## Arguments

- collection:

  the collection directory or URL (e.g. `<base>/gazetteer/<slug>`), its
  `h3/` directory, or the `membership.json` itself (local path or URL).
  A bare slug (no `/`) is taken under `base`.

- res:

  H3 resolution of the membership to use (default 7, the store's base
  resolution).

- base:

  the gazetteer root for a bare slug.

## Value

a list with `files` (paths or URLs of the membership parquet files at
`res`), `res`, and `info` (the parsed `membership.json`).

## Examples

``` r
if (FALSE) { # \dontrun{
obis_place_membership("noaa_aoa_socal")$files
} # }
```
