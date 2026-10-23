# SQL rolling a cell-sorted species table up to a coarser resolution

One row per (cell at `res`, aphiaid) from a finer species table with the
columns of `species_flat/res=<r>.parquet`: `n` summed, `year_min` the
least and `year_max` the greatest over the finer cells (NULL only when
every finer row's year is NULL), `name_key` carried (one per aphiaid).
This is the atlas's `sumBySpecies` over a cell's children, written once
in the release; it equals
[`obis_h3_species_sql()`](https://marinebon.org/obisindicators/reference/obis_h3_species_sql.md)
at `res` straight from the store, since that rolls the same `occ_h3`
tier up with the same sums, minima and maxima.

## Usage

``` r
obis_h3_species_rollup_sql(from, res)
```

## Arguments

- from:

  a table name or a table function such as
  `read_parquet('species_flat/res=3.parquet')`, with `cell_id`,
  `name_key`, `aphiaid`, `n`, `year_min` and `year_max`.

- res:

  the coarser H3 resolution (0 to 15; coarser than `from`'s).

## Value

a SQL string (a SELECT, unordered) with the columns
`cell_id, name_key, aphiaid, n, year_min, year_max`.

## Examples

``` r
cat(obis_h3_species_rollup_sql("read_parquet('species_flat/res=3.parquet')", 1))
#> SELECT CAST(h3_cell_to_parent(cell_id, 1) AS BIGINT) AS cell_id,
#>        name_key::INTEGER AS name_key, aphiaid::BIGINT AS aphiaid, SUM(n)::BIGINT AS n,
#>        MIN(year_min)::SMALLINT AS year_min, MAX(year_max)::SMALLINT AS year_max
#> FROM read_parquet('species_flat/res=3.parquet')
#> GROUP BY 1, 2, 3
```
