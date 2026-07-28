# Build an h3t tile SQL query for an Essential Ocean Variable

Routes to the precomputed `idx_h3_eov` layer when it can (no year
filter, one EOV — as fast as the all-taxa `idx_h3` path), otherwise
falls back to a live aggregation over `occ_h3` filtered to the EOV's
AphiaID subtree via
[`obis_h3t_sql()`](https://marinebon.org/obisindicators/reference/obis_h3t_sql.md).
Projects exactly `cell_id, value, n`.

## Usage

``` r
obis_eov_sql(
  eov,
  indicator = c("es", "sp", "shannon", "n"),
  years = NULL,
  esn = 50L,
  res_max = 7L,
  res_placeholder = "{{res}}",
  live = NULL
)
```

## Arguments

- eov:

  EOV name(s); see
  [`obis_eov_seeds()`](https://marinebon.org/obisindicators/reference/obis_eov_seeds.md).
  Multiple names always take the live path (the precomputed layer stores
  one EOV per row).

- indicator:

  one of `"es"` (ES50), `"sp"`, `"shannon"`, `"n"`.

- years:

  optional `c(min, max)` year range; forces the live path.

- esn:

  expected sample size for ES(n); default 50.

- res_max:

  cap on H3 resolution (1-7).

- res_placeholder:

  resolution placeholder; default `"{{res}}"`.

- live:

  force the live `occ_h3` path (e.g. against a store where
  [`obis_eov_bake()`](https://marinebon.org/obisindicators/reference/obis_eov_bake.md)
  has not been run). Default: only when it must.

## Value

a SQL string.

## Examples

``` r
obis_eov_sql("seaTurtles")
#> [1] "SELECT cell_id, es AS value, n FROM idx_h3_eov WHERE eov = 'seaTurtles' AND res = LEAST({{res}}, 7)"
obis_eov_sql("fish", indicator = "n", years = c(2000, 2020))
#> [1] "WITH RECURSIVE taxon_tree AS (\nSELECT taxonID, parentNameUsageID\nFROM taxon\nWHERE taxonID IN (1829, 1517375, 152352)\nUNION ALL\nSELECT t.taxonID, t.parentNameUsageID\nFROM taxon t\nJOIN taxon_tree tt ON t.parentNameUsageID = tt.taxonID\nWHERE t.parentNameUsageID IS NOT NULL), src AS (\n  SELECT CAST(h3_cell_to_parent(cell_id, LEAST({{res}}, 7)) AS BIGINT) AS cell_id,\n         species, SUM(records) AS ni\n  FROM occ_h3\n  WHERE res = CASE WHEN LEAST({{res}}, 7) <= 3 THEN 3 WHEN LEAST({{res}}, 7) <= 5 THEN 5 ELSE 7 END\n    AND aphiaid IN (SELECT taxonID FROM taxon_tree)\n        AND date_year >= 2000\n        AND date_year <= 2020\n  GROUP BY 1, 2)\nSELECT cell_id, SUM(ni) AS value, SUM(ni) AS n FROM src GROUP BY cell_id"
```
