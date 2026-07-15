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
  aphiaid = NULL,
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

- aphiaid:

  optional integer WoRMS AphiaID(s). Filters `occ_h3` to every
  descendant taxon of these ids (any rank), resolved from the baked
  `taxon` table. Takes precedence over `taxon`; combines with `years`.

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

Query routing (fastest first):

- no `taxon`/`aphiaid`/`years` filter → precomputed all-taxa `idx_h3`
  layer.

- a single value of one precomputed rank (phylum/class/order) with no
  `years` → precomputed `idx_h3_taxon` layer (just as fast).

- an `aphiaid` filter → live indicator over `occ_h3`, filtered to the
  AphiaID subtree resolved from the baked `taxon` table via a recursive
  CTE (arbitrary rank, e.g. Infraorder Cetacea); see
  [`obis_taxon_children()`](http://marinebon.org/obisindicators/reference/obis_taxon_children.md).

- anything else (finer rank, multiple values, or a year range) → live
  indicator computed on the fly from the species-level `occ_h3` store,
  selecting the resolution tier that matches the tile zoom.
