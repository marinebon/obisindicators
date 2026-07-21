# Scaling OBIS observations across H3 resolutions

H3 is a hierarchy: each drop in resolution aggregates ~7 child hexagons
into a parent. Summarizing OBIS the same query at different H3
resolutions therefore trades **spatial detail** against **per-cell
sample size** and **query cost**. This article walks those trade-offs
and the choices they force in the `h3t` serving design — especially for
the live children-taxa and SPUE paths from
[`vignette("taxon_children")`](https://marinebon.org/obisindicators/articles/taxon_children.md).

``` r

library(obisindicators)
library(DBI); library(duckdb); library(dplyr)

con <- dbConnect(duckdb(), "/share/data/obis/obis_h3.duckdb", read_only = TRUE)
dbExecute(con, "LOAD h3;")
```

## Cells vs. density across resolution

Take one taxon — all Cetacea (AphiaID 2688) — and summarize it at every
stored resolution. As resolution rises, cell count climbs roughly ×7 per
step while the median records-per-cell falls: the signal spreads
thinner.

``` r

res_summary <- function(res) {
  sql <- obis_h3t_sql("n", aphiaid = 2688, res_placeholder = as.character(res))
  d <- dbGetQuery(con, sql)
  tibble(res = res, n_cells = nrow(d),
         records = sum(d$value), median_per_cell = median(d$value))
}
purrr::map_dfr(1:7, res_summary)
#> # res 1: few big cells, high density ... res 7: many cells, sparse
```

The store keeps species-level `occ_h3` at only three tiers (3 / 5 / 7);
a query at res 1–2 rolls up from tier 3, res 4 from tier 5, res 6 from
tier 7 (see
[`obis_h3t_sql()`](https://marinebon.org/obisindicators/reference/obis_h3t_sql.md)).
Rolling *up* is cheap; the expense is the base-tier scan.

## Precomputed vs. live query cost

Unfiltered and coarse-rank (phylum/class/order) indicators are
**precomputed** into `idx_h3` / `idx_h3_taxon` (one row per cell, res
1–7) — served with a plain indexed lookup at any resolution. The
children-taxa (`aphiaid=`) and SPUE paths have no precomputed layer:
they aggregate `occ_h3` **live**, resolving the WoRMS subtree with a
recursive CTE on each request.

``` r

bench <- function(label, sql) {
  t <- system.time(dbGetQuery(con, sql))[["elapsed"]]
  tibble(query = label, seconds = round(t, 3))
}
bind_rows(
  bench("idx_h3 (precomputed, res 7)", obis_h3t_sql("es", res_placeholder = "7")),
  bench("aphiaid Cetacea (live, res 7)",
        obis_h3t_sql("n", aphiaid = 2688, res_placeholder = "7")),
  bench("aphiaid diatoms (live, res 7)",   # ~71k descendant taxa
        obis_h3t_sql("n", aphiaid = 148899, res_placeholder = "7")))
```

Live cost grows with (a) the breadth of the subtree (a class resolves
tens of thousands of descendants) and (b) the base-tier row count at
fine resolution. The server caps a single statement at
`H3T_STMT_TIMEOUT_MS` (8 s); a broad taxon at res 7 can approach it.

## The SPUE denominator gets sparse

The effort proxy divides by the *denominator* (effort-taxon records per
cell). That denominator thins with resolution faster than intuition
suggests: a ratio of 1/1 and 30/60 both render, but only the latter is
trustworthy. Track the fraction of cells whose effort `n` falls below a
reliability floor:

``` r

floor_n <- 20
sparsity <- function(res) {
  sql <- obis_spue_sql(num_aphiaid = 137111, den_aphiaid = 2688,  # dolphin / Cetacea
                       res_placeholder = as.character(res))
  d <- dbGetQuery(con, sql)
  tibble(res = res, n_cells = nrow(d),
         pct_below_floor = mean(d$n < floor_n))
}
purrr::map_dfr(c(2, 4, 6, 7), sparsity)
#> pct_below_floor rises steeply with res — fine-res SPUE is mostly low-effort noise
```

## Design guidance

- **Prefer a precomputed layer** where the filter is knowable ahead of
  time. All-taxa and phylum/class/order maps hit `idx_h3` /
  `idx_h3_taxon` and are resolution-independent in cost. If a
  children-taxa filter is used heavily (e.g. a fixed set of EOV groups),
  precompute it the same way.
- **Cap `res_max`** for live paths. Serving a broad subtree at res 7 is
  the worst case; `obis_h3t_sql(res_max = 5)` keeps hexagons coarser
  (and the scan cheaper) at high zoom.
- **Consider a descendant-closure table**
  (`ancestor_aphiaid → descendant_aphiaid`) baked beside `taxon`,
  turning the per-request recursive walk into a join — the natural next
  step if live children maps become hot.
- **Read SPUE with its `n`.** Style the map by `value` but gate trust on
  the effort `n`; at fine resolution most cells are low-effort.
  Aggregating to a coarser resolution (or a larger effort taxon)
  restores a usable denominator.

``` r

dbDisconnect(con, shutdown = TRUE)
```
