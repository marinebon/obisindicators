# SQL for a WoRMS subtree's indicators from the exported species table

What a browser runs against the release instead of asking h3t: the
species files of one resolution joined to the lookup, filtered to the
aphiaids whose `lineage` contains a seed, and summarized per cell with
the store's own indicator SQL (`.h3t_indicators_sql()`, species counted
by `name_key`). It reproduces the h3t subtree (the recursive CTE down
`taxon` from the seeds) cell for cell: `n` and `sp` exactly, Shannon,
Simpson and ES to floating point.

## Usage

``` r
obis_h3_species_subtree_sql(
  release_dir,
  aphiaid,
  res,
  esn = 50L,
  classes = NULL
)
```

## Arguments

- release_dir:

  the release directory written by
  [`obis_h3_export_parquet()`](https://marinebon.org/obisindicators/reference/obis_h3_export_parquet.md)
  (holding `species/`).

- aphiaid:

  one or more seed WoRMS AphiaIDs (e.g. 2, Animalia).

- res:

  a resolution of the species table.

- esn:

  expected sample size for ES(n) (default 50).

- classes:

  optional classes to read (the partitions a class-bounded taxon needs;
  `NA` reads the `_none` file); NULL reads every partition.

## Value

a SQL string with columns `h3, cell_id, n, sp, shannon, simpson, es`,
ordered by cell_id.
