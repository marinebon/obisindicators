# Write a query to one Parquet file per partition, sorted

The explicit per-partition writer of the species table. DuckDB's
`COPY ... PARTITION_BY` wrote thousands of files per resolution for 301
classes and lost the sort order (spike 2), so this materializes `sql`
once, then runs one `COPY` per partition value to
`dir/<key>=<value>[/<key2>=<value2>]/data_0.parquet`, each
`ORDER BY order_by` with fixed row groups, so a reader finds a cell's
rows in one row group from the `cell_id` statistics. A NULL partition
value is written as `null_value` (`_none`; DuckDB-WASM reads
`__HIVE_DEFAULT_PARTITION__` as a string), and other values are
percent-encoded where needed (DuckDB decodes them on read). The
partition columns are left out of the files (they are in the path).

## Usage

``` r
obis_h3_write_partitions(
  con,
  sql,
  dir,
  partition_by = "class",
  order_by = c("cell_id", "aphiaid"),
  null_value = "_none",
  compression = "zstd",
  row_group_size = 100000L
)
```

## Arguments

- con:

  a DBI connection to DuckDB.

- sql:

  a SELECT yielding the partition columns and the file columns.

- dir:

  output directory (created).

- partition_by:

  the partition column(s), outermost first (default `"class"`).

- order_by:

  the sort columns within a file (default `c("cell_id", "aphiaid")`).

- null_value:

  the on-disk value of a NULL partition (default `"_none"`).

- compression:

  Parquet codec (default `"zstd"`).

- row_group_size:

  rows per row group (default 100000; DuckDB rounds up to a multiple of
  2048).

## Value

a data frame, one row per partition: the partition columns, `path`
(relative to `dir`) and `rows`.
