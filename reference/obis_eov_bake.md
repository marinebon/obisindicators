# Bake the EOV membership and precomputed-indicator layers into a store

Adds two tables to an obis_h3 DuckDB store:

- `eov` — `(eov, taxonID)` membership, each EOV's seeds expanded to
  their full descendant set over the baked WoRMS `taxon` table.

- `idx_h3_eov` — precomputed indicators per `(eov, res)` for res 1-7, so
  an EOV tile map reads a small clustered lookup instead of
  re-aggregating `occ_h3` on every tile.

## Usage

``` r
obis_eov_bake(con, eov = NULL, esn = 50L, verbose = TRUE)
```

## Arguments

- con:

  a `DBI` connection to a **writable** store with `occ_h3` + `taxon`,
  with the duckdb `h3` extension loaded.

- eov:

  EOV name(s) to bake; default all.

- esn:

  expected sample size for ES(n); default 50.

- verbose:

  message progress.

## Value

invisibly, a data frame of `eov` and its member-taxon count.

## Details

Requires `taxon` (see `data-raw/migrate_add_taxon.R`) and, for complete
coverage, a closed taxon tree (see
[`obis_taxon_fill_gaps()`](https://marinebon.org/obisindicators/reference/obis_taxon_fill_gaps.md))
— any EOV member whose AphiaID is missing from `taxon` is silently
excluded.
