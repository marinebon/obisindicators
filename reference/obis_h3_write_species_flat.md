# Write the species_flat roll-ups and the parent split

From the finest cell-sorted species file
`flat_dir/res=<from_res>.parquet` (written by
[`obis_h3_export_parquet()`](https://marinebon.org/obisindicators/reference/obis_h3_export_parquet.md)),
writes

## Usage

``` r
obis_h3_write_species_flat(
  con,
  flat_dir,
  from_res = 3L,
  res = c(1L, 2L),
  split = c(`3` = 1L),
  row_group_rows = 10000L,
  split_row_group_rows = 2048L,
  compression = "zstd"
)
```

## Arguments

- con:

  a DBI connection to DuckDB with the `h3` extension loaded.

- flat_dir:

  the release's `species_flat/` folder.

- from_res:

  the resolution of the file the others come from (default 3).

- res:

  the coarser resolutions to roll up to (default 1 and 2).

- split:

  a named integer vector, resolution = parent resolution, of the files
  to split (default `c("3" = 1L)`); `NULL` writes none. A split
  resolution must be `from_res` or one of `res`.

- row_group_rows:

  rows per row group of the roll-ups (default 10000).

- split_row_group_rows:

  rows per row group of the split files (default 2048, one DuckDB
  vector; a group holds at most twice that).

- compression:

  Parquet codec (default `"zstd"`).

## Value

a data frame, one row per file written: `path` (relative to the release,
`species_flat/...`), `res`, `parent` (NA for a roll-up), `rows`,
`bytes`.

## Details

- `res=<r>.parquet` for each `r` in `res` (coarser than `from_res`): one
  row per cell and species,
  [`obis_h3_species_rollup_sql()`](https://marinebon.org/obisindicators/reference/obis_h3_species_rollup_sql.md),
  so a coarse hexagon's list is its own rows, not its children's;

- `res=<s>/p=<parent>.parquet` for each `s = names(split)`: the rows of
  `res=<s>.parquet` under one parent cell at `split[[s]]` (the parent's
  lowercase hex id), so a page reads a file small enough for its footer
  to come with the first range read.

Every file written has the columns
`cell_id, name_key, aphiaid, n, year_min, year_max` (no `h3`: `cell_id`
gives it, and its string statistics are the largest part of a footer),
sorted by `cell_id, aphiaid`, in row groups of `row_group_rows` (the
roll-ups) or `split_row_group_rows` (the split), so the `cell_id`
statistics of consecutive groups ascend (a cell's rows lie in one group
or in adjacent ones). As for the layer files, DuckDB writes a group of
at most 2 x the size asked (v20261012's split: 4,081 rows at most for
2,048). `res=<from_res>.parquet` is read, never rewritten.
