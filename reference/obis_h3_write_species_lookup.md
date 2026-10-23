# Write the species lookup with its EOV, and the split lineage file

Writes `dir/species.parquet` (the rows of `lookup`, ordered by aphiaid,
with the column `eov` of
[`obis_h3_species_eov_sql()`](https://marinebon.org/obisindicators/reference/obis_h3_species_eov_sql.md)
after the lookup's own columns) and `dir/lineage.parquet`
(`aphiaid, name_key, lineage` only, the same rows), both in row groups
of `row_group_rows`, so a WoRMS subtree reads the lineage without the
names and a list of species reads the names without the lineage. Without
an `eov` table (`eov = NULL`) the column is left out. The rows are
`lookup`'s, one per aphiaid, ordered by aphiaid (the order
[`obis_h3_export_parquet()`](https://marinebon.org/obisindicators/reference/obis_h3_export_parquet.md)
writes); each file is written to a temporary name and renamed, so
`lookup` may read the `species.parquet` it replaces.

## Usage

``` r
obis_h3_write_species_lookup(
  con,
  lookup,
  dir,
  eov = "eov",
  row_group_rows = 10000L,
  compression = "zstd"
)
```

## Arguments

- con:

  a DBI connection to DuckDB.

- lookup:

  a table name or a table function (`read_parquet('...')`) with the
  lookup columns of
  [`obis_h3_species_lookup_sql()`](https://marinebon.org/obisindicators/reference/obis_h3_species_lookup_sql.md).

- dir:

  output folder (the release's `species/`).

- eov:

  the EOV membership table, or NULL (default `"eov"`).

- row_group_rows:

  rows per row group (default 10000).

- compression:

  Parquet codec (default `"zstd"`).

## Value

a data frame, one row per file: `path` (relative to the release),
`rows`, `bytes`, with the attribute `eov` (the number of aphiaids per
EOV, NA for none).

## Details

No IUCN Red List column is written: the store holds no Red List field
(its `occ_h3` and `taxon` tables carry none).
