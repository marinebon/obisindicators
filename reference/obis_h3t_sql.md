# Build an h3t tile SQL query for an OBIS biodiversity indicator

Generates the read-only `SELECT` (projecting exactly
`cell_id, value, n`) that the `h3t` service base64-decodes, validates,
and executes per tile. `{{res}}` is substituted server-side with the
tile's H3 resolution.

## Usage

``` r
obis_h3t_sql(
  indicator = c("es", "sp", "shannon", "n"),
  taxon = NULL,
  years = NULL,
  esn = 50L,
  res_max = 7L,
  res_placeholder = "{{res}}"
)
```

## Arguments

- indicator:

  one of `"es"` (ES50), `"sp"` (richness), `"shannon"`, `"n"` (#
  records).

- taxon:

  optional named list/vector restricting taxa, names among `phylum`,
  `class`, `order`, `family`, `genus`, `species`, e.g.
  `list(class = "Aves")` or `list(phylum = c("Mollusca", "Cnidaria"))`.

- years:

  optional `c(min, max)` year range (either may be `NA`).

- esn:

  expected sample size for ES(n); default 50.

- res_max:

  cap on the H3 resolution (1-7). Lower = coarser/bigger hexagons at a
  given map zoom (the "base zoom level" control); the store's finest
  resolution is 7. Default 7 (track zoom up to the finest).

- res_placeholder:

  the resolution placeholder; default `"{{res}}"`.

## Value

a single-line-friendly SQL string.

## Details

With no `taxon`/`years` filter the query reads the precomputed `idx_h3`
layer (fast). With a filter it computes the indicator on the fly from
the species-level `occ_h3` store, selecting the resolution tier that
matches the tile zoom.
