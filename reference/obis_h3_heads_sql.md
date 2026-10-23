# SQL for the pre-aggregated heads at one resolution

The indicators of every head (a taxon spanning several classes, listed
by
[`obis_h3_species_heads()`](https://marinebon.org/obisindicators/reference/obis_h3_species_heads.md))
at one resolution, from `occ_h3` and the species lookup: an aphiaid
belongs to a head when the head's aphiaid is in its `lineage`, species
are counted by `name_key`, and the cells come from the coarsest `occ_h3`
tier at least as fine as `res` (res 4 from the res-5 tier). This is the
subtree
[`obis_h3_species_subtree_sql()`](https://marinebon.org/obisindicators/reference/obis_h3_species_subtree_sql.md)
computes from the exported species files, done once for the release, so
a reader draws a head as an ordinary taxon layer
(`taxon/rank=<rank>/taxon=<name>/res=<r>/`) and never reads the class
files.

## Usage

``` r
obis_h3_heads_sql(
  res,
  heads,
  lookup = "species_lookup",
  from = "occ_h3",
  esn = 50L
)
```

## Arguments

- res:

  H3 resolution, 1 to 7.

- heads:

  the table (or a parenthesised SELECT) of heads, with columns
  `aphiaid`, `rank` and `taxon` (the layout keys).

- lookup:

  the table of
  [`obis_h3_species_lookup_sql()`](https://marinebon.org/obisindicators/reference/obis_h3_species_lookup_sql.md)'s
  rows.

- from:

  the species-level table (default `"occ_h3"`).

- esn:

  expected sample size for ES(n) (default 50).

## Value

a SQL string with columns
`rank, taxon, res, h3, cell_id, n, sp, shannon, simpson, es`.

## Examples

``` r
cat(obis_h3_heads_sql(4, "heads", "species_lookup"))
#> SELECT rank, taxon, 4::UTINYINT AS res, lower(printf('%x', cell_id)) AS h3, cell_id,
#>        n::BIGINT AS n, sp::BIGINT AS sp, shannon, simpson, es
#> FROM (WITH src AS (
#>   SELECT m.rank, m.taxon, CAST(h3_cell_to_parent(o.cell_id, 4) AS BIGINT) AS cell_id,
#>        m.name_key AS species, SUM(o.records) AS ni
#> FROM occ_h3 o
#> JOIN (SELECT h.rank, h.taxon, l.aphiaid, l.name_key
#>       FROM species_lookup l, unnest(l.lineage) AS u(node)
#>       JOIN heads h ON h.aphiaid = u.node) m ON o.aphiaid = m.aphiaid
#> WHERE o.res = 5
#> GROUP BY 1, 2, 3, 4),
#> tot AS (
#>   SELECT rank, taxon, cell_id, SUM(ni) AS n FROM src GROUP BY rank, taxon, cell_id),
#> per AS (
#>   SELECT s.rank, s.taxon, s.cell_id, s.ni, t.n,
#>     CASE
#>       WHEN t.n - s.ni >= 50 THEN 1 - exp(
#>              lgamma(t.n - s.ni + 1) + lgamma(t.n - 50 + 1)
#>            - lgamma(t.n - s.ni - 50 + 1) - lgamma(t.n + 1))
#>       WHEN t.n >= 50 THEN 1
#>       ELSE NULL END AS esi
#>   FROM src s JOIN tot t USING (rank, taxon, cell_id))
#> SELECT rank, taxon, cell_id,
#>   ANY_VALUE(n)                                       AS n,
#>   COUNT(*)                                           AS sp,
#>   -SUM((ni::DOUBLE / n) * ln(ni::DOUBLE / n))        AS shannon,
#>   SUM((ni::DOUBLE / n) * (ni::DOUBLE / n))           AS simpson,
#>   SUM(esi)                                           AS es
#> FROM per GROUP BY rank, taxon, cell_id) _h
```
