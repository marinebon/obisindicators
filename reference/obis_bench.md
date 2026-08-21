# Benchmark queries against a store

Times each SQL statement: the first (cold) run and the median of `reps`
further (warm) runs, plus the number of rows returned. Use with
[`obis_bench_queries()`](https://marinebon.org/obisindicators/reference/obis_bench_queries.md)
for the paper's default set, or any named character vector of SQL.

## Usage

``` r
obis_bench(con, queries, reps = 3L)
```

## Arguments

- con:

  connection from
  [`obis_store_connect()`](https://marinebon.org/obisindicators/reference/obis_store_connect.md).

- queries:

  named character vector of SQL statements (no `{{res}}` placeholders —
  bind them first, e.g. via `res_placeholder`).

- reps:

  number of warm repetitions after the cold run (default 3).

## Value

data frame with `label`, `rows`, `cold_s`, `warm_s` (median).
