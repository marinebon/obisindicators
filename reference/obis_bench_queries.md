# The paper's default benchmark query set

Builds the SQL for the four serving paths at each resolution: the
precomputed all-taxa layer (`idx_h3`), the precomputed EOV layer
(`idx_h3_eov`), the live EOV subtree over `occ_h3`, and the SPUE effort
proxy (two recursive subtrees).

## Usage

``` r
obis_bench_queries(
  res = c(3L, 5L, 7L),
  eov = "fish",
  num_aphiaid = 137092L,
  den_aphiaid = 2688L,
  esn = 50L
)
```

## Arguments

- res:

  resolutions to benchmark (default 3, 5, 7).

- eov:

  EOV for the precomputed/live comparison (default `"fish"`).

- num_aphiaid, den_aphiaid:

  SPUE target/effort AphiaIDs (default humpback whale 137092 over
  Cetacea 2688).

- esn:

  expected sample size for ES(n).

## Value

named character vector of SQL, ready for
[`obis_bench()`](https://marinebon.org/obisindicators/reference/obis_bench.md).
