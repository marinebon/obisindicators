# Add the 0.12 species files to a built obis-h3 release

Amends a release written by
[`obis_h3_export_parquet()`](https://marinebon.org/obisindicators/reference/obis_h3_export_parquet.md)
0.11 (or later) in place, from its own files and the store's `eov`
table, without re-running the export:

## Usage

``` r
obis_h3_amend_species(
  con,
  release_dir,
  from_res = 3L,
  res_flat = c(1L, 2L),
  split = c(`3` = 1L),
  eov = "eov",
  row_group_rows = 10000L,
  split_row_group_rows = 2048L,
  manifest = TRUE,
  compression = "zstd"
)
```

## Arguments

- con:

  a DBI connection to DuckDB with the `h3` extension loaded (the store,
  for its `eov` table).

- release_dir:

  the release directory.

- from_res:

  the resolution of the existing flat file (default 3).

- res_flat:

  the coarser resolutions to roll up to (default 1 and 2).

- split:

  resolution = parent resolution of the split (default `c("3" = 1L)`).

- eov:

  the EOV membership table, or NULL for no `eov` column.

- row_group_rows:

  rows per row group of the roll-ups, the lookup and the lineage file
  (default 10000).

- split_row_group_rows:

  rows per row group of the split (default 2048).

- manifest:

  also update `files.parquet` (default TRUE).

- compression:

  Parquet codec (default `"zstd"`).

## Value

invisibly, a data frame of the files written (`path`, `rows`, `bytes`),
with the attribute `eov` (aphiaids per EOV).

## Details

- `species/species.parquet` rewritten with the column `eov`
  ([`obis_h3_species_eov_sql()`](https://marinebon.org/obisindicators/reference/obis_h3_species_eov_sql.md);
  same rows, same order) and `species/lineage.parquet` beside it
  ([`obis_h3_write_species_lookup()`](https://marinebon.org/obisindicators/reference/obis_h3_write_species_lookup.md));

- `species_flat/res=<r>.parquet` for `res_flat` and the split
  `species_flat/res=<s>/p=<parent>.parquet`
  ([`obis_h3_write_species_flat()`](https://marinebon.org/obisindicators/reference/obis_h3_write_species_flat.md)),
  from `species_flat/res=<from_res>.parquet`, which is not rewritten;

- `release.json`: `layers.species_flat` (resolutions, the split's
  `template_parent`, `parent_res`, `by_res`, `split`), `layers.species`
  (`lookup_columns` with `eov`, `lineage`, `eov`, `lookup_bytes`) and,
  with `manifest = TRUE`, `files.parquet` (the lookup's new size, the
  new files added; every other row kept).

The collections are not written here: run
[`obis_h3_stac_collection()`](https://marinebon.org/obisindicators/reference/obis_h3_stac_collection.md)
and
[`obis_h3_stac_stable()`](https://marinebon.org/obisindicators/reference/obis_h3_stac_stable.md)
after.
