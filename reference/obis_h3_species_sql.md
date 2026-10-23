# SQL for the species x hex x count table at one resolution

One row per (cell, aphiaid) from the store's `occ_h3`, with `n` the
number of records and `year_min`, `year_max` the first and last year
recorded (the Cell pane's first and last year; NULL when no record has a
year). A resolution that is an `occ_h3` tier (3, 5, 7) reads that tier;
any other is rolled up from the next finer tier with
`h3_cell_to_parent()` (res 4 from the res-5 tier, as in the decade
layers). Rows with a NULL `aphiaid` are left out (no taxon filter can
reach them).

## Usage

``` r
obis_h3_species_sql(
  res,
  from = "occ_h3",
  lookup = NULL,
  decade = FALSE,
  decades = NULL
)
```

## Arguments

- res:

  H3 resolution, 1 to 7.

- from:

  the species-level table (default `"occ_h3"`).

- lookup:

  optional name of the lookup table to join (see above).

- decade:

  per decade (`decade = floor(date_year / 10) * 10`, records with a year
  only) instead of over all years (default FALSE).

- decades:

  with `decade = TRUE`, the decades to keep (default NULL: all).

## Value

a SQL string (a SELECT).

## Details

With `lookup`, the name of a table holding
[`obis_h3_species_lookup_sql()`](https://marinebon.org/obisindicators/reference/obis_h3_species_lookup_sql.md)'s
rows, the result has the columns of a species file plus the partition
key:
`h3 VARCHAR, cell_id BIGINT, name_key INTEGER, aphiaid BIGINT, n BIGINT, year_min SMALLINT, year_max SMALLINT, class VARCHAR`
(the lookup's class, so one aphiaid always lands in one partition).
Without it, `cell_id, aphiaid, n, year_min, year_max`. Per decade, the
years are those within the decade.

## Examples

``` r
cat(obis_h3_species_sql(4))
#> SELECT CAST(h3_cell_to_parent(cell_id, 4) AS BIGINT) AS cell_id, aphiaid::BIGINT AS aphiaid, SUM(records)::BIGINT AS n,
#>        MIN(date_year)::SMALLINT AS year_min, MAX(date_year)::SMALLINT AS year_max
#> FROM occ_h3
#> WHERE res = 5 AND aphiaid IS NOT NULL
#> GROUP BY ALL
```
