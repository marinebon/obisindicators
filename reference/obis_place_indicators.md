# Indicators per place, pooled from area-weighted H3 cells

Computes the indicators of each place of a polygon collection from the
species records of the H3 cells that intersect it, weighting every
cell's records by the cell's `share` of area inside the place: for each
place and species, `ni = sum(records * share)` over the member cells,
and the indicators are those of
[`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md)
on those pooled counts (same SQL as the store's precomputed layers). The
layers are `all` (all taxa) and `eov` (one row per EOV, by the store's
`eov` membership), each for all years (`decade` NA) and per decade
(`decade = floor(date_year / 10) * 10`, records without a year left
out), as in
[`obis_h3_export_parquet()`](https://marinebon.org/obisindicators/reference/obis_h3_export_parquet.md).

## Usage

``` r
obis_place_indicators(
  con,
  membership,
  esn = 50L,
  res = 7L,
  decades = TRUE,
  eov = TRUE,
  verbose = FALSE
)
```

## Arguments

- con:

  connection to an obis_h3 store with `occ_h3` (read-only is fine), with
  the duckdb `h3` extension loaded (see
  [`obis_store_connect()`](https://marinebon.org/obisindicators/reference/obis_store_connect.md)).

- membership:

  the place-cell membership, columns `place_id`, `h3` (hex string) and
  `share`: a data frame, the name of a table or view in `con`, a
  character vector of parquet paths or URLs, a gazetteer collection
  (directory, URL, `membership.json` or slug, see
  [`obis_place_membership()`](https://marinebon.org/obisindicators/reference/obis_place_membership.md)),
  or the list that function returns. Its cells must be at resolution
  `res`.

- esn:

  expected sample size for ES(n); default 50.

- res:

  H3 resolution of the membership cells (default 7). The store's
  `occ_h3` tier for `res` is used; finer tiers are rolled up to `res`.

- decades:

  decades (first year) to compute besides all years: `TRUE` (default)
  for 1960-2020 as in the export, `FALSE` or `NULL` for none, or an
  integer vector.

- eov:

  EOV layers: `TRUE` (default) every EOV in the store's `eov` table
  (skipped when the store has none), `FALSE` none, or EOV names.

- verbose:

  message progress.

## Value

a data frame, one row per (place, layer, key, decade) with records:
`place_id`, `layer` (`"all"` or `"eov"`), `key` (`""` or the EOV name),
`decade` (NA = all years), `n` (sum of records x share, double), `sp`
(species with a weighted count \> 0), `shannon`, `simpson` (sum of p^2),
`es` (ES(`esn`) on the weighted counts, NA where `n < esn`), `cells`
(member cells with records in that layer and decade) and `area` (sum of
`share` over those cells, in cells).

## Details

**Science caveat.** These are true per-place indices computed from
pooled, area-weighted species counts, not means of hexagon values: a
place's richness or ES(50) is that of the place as one sample. Because
of the weighting, `n` and the per-species counts are fractional (a cell
half inside the place contributes half its records). Richness `sp`
counts every species with any weighted record inside the place, so a
species seen only in a cell that barely touches the place still counts
once. ES(`esn`) uses Hurlbert's formula through
[`lgamma()`](https://rdrr.io/r/base/Special.html), which is defined for
the real-valued counts; it is NA where the weighted `n` is below `esn`.
Places with no records in a layer have no row for it.

## Examples

``` r
if (FALSE) { # \dontrun{
con <- obis_store_connect("~/data/obis/obis_h3.duckdb")
obis_place_indicators(con, "noaa_aoa_socal")
} # }
```
