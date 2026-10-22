# SQL for the per-year indicator layers

The indicators of one resolution per year (and per EOV), computed from
`occ_h3` with the store's indicator SQL (the same
`.h3t_indicators_sql()` that builds `idx_h3`, `idx_h3_eov` and the
decade layers): `n` = records, `sp` = distinct species names, Shannon,
Simpson and ES(`esn`), grouped by cell and
`year = CAST(date_year AS INTEGER)`. Records without a year are left
out. The cells come from the coarsest `occ_h3` tier at least as fine as
`res` (res 4 is rolled up from the res-5 tier). EOV membership is the
store's `eov` table (`occ_h3.aphiaid = eov.taxonID`).

## Usage

``` r
obis_h3_year_sql(res, eov = FALSE, years = NULL, esn = 50L, from = "occ_h3")
```

## Arguments

- res:

  H3 resolution, 1 to 7.

- eov:

  per EOV as well (needs the `eov` table; default FALSE).

- years:

  years to keep (default NULL: every year present).

- esn:

  expected sample size for ES(n) (default 50).

- from:

  the species-level table (default `"occ_h3"`).

## Value

a SQL string with columns
`[eov,] year, res, h3, cell_id, n, sp, shannon, simpson, es`.

## Examples

``` r
cat(obis_h3_year_sql(4))
#> SELECT year, 4::UTINYINT AS res, lower(printf('%x', cell_id)) AS h3, cell_id, n, sp, shannon, simpson, es FROM (WITH src AS (
#>   SELECT CAST(date_year AS INTEGER) AS year,
#>        CAST(h3_cell_to_parent(cell_id, 4) AS BIGINT) AS cell_id,
#>        species, SUM(records) AS ni
#> FROM occ_h3
#> WHERE res = 5 AND date_year IS NOT NULL
#> GROUP BY 1, 2, 3),
#> tot AS (
#>   SELECT year, cell_id, SUM(ni) AS n FROM src GROUP BY year, cell_id),
#> per AS (
#>   SELECT s.year, s.cell_id, s.ni, t.n,
#>     CASE
#>       WHEN t.n - s.ni >= 50 THEN 1 - exp(
#>              lgamma(t.n - s.ni + 1) + lgamma(t.n - 50 + 1)
#>            - lgamma(t.n - s.ni - 50 + 1) - lgamma(t.n + 1))
#>       WHEN t.n >= 50 THEN 1
#>       ELSE NULL END AS esi
#>   FROM src s JOIN tot t USING (year, cell_id))
#> SELECT year, cell_id,
#>   ANY_VALUE(n)                                       AS n,
#>   COUNT(*)                                           AS sp,
#>   -SUM((ni::DOUBLE / n) * ln(ni::DOUBLE / n))        AS shannon,
#>   SUM((ni::DOUBLE / n) * (ni::DOUBLE / n))           AS simpson,
#>   SUM(esi)                                           AS es
#> FROM per GROUP BY year, cell_id) _d
```
