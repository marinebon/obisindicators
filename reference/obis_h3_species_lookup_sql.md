# SQL for the species lookup of the species x hex x count table

One row per aphiaid in `occ_h3`:
`aphiaid BIGINT, name_key INTEGER, species, genus, family, "order", class, phylum, lineage BIGINT[], records BIGINT`.

## Usage

``` r
obis_h3_species_lookup_sql(from = "occ_h3", taxon = "taxon", max_depth = 64L)
```

## Arguments

- from:

  the species-level table (default `"occ_h3"`).

- taxon:

  the WoRMS taxon table (`taxonID`, `parentNameUsageID`), or NULL.

- max_depth:

  guard against a cycle in the taxonomy (default 64).

## Value

a SQL string (a SELECT, ordered by aphiaid).

## Details

`name_key` is a dense integer per distinct species name (ordered by
name): richness counts species *names*, as h3t and
`.h3t_indicators_sql()` group by `occ_h3.species`, and some names carry
several aphiaids (2,140 in the 2026-10 global store), so counting
aphiaids would overstate `sp`.

`lineage` is the aphiaid itself followed by its ancestors, walked up
`taxon.parentNameUsageID` from the occurrence's own aphiaid (accepted or
not), so `list_contains(lineage, A)` selects exactly the aphiaids the
recursive CTE of h3t /
[`obis_taxon_children()`](https://marinebon.org/obisindicators/reference/obis_taxon_children.md)
finds walking down from `A`. A synonym keeps its own parent chain, not
its accepted name's. Without a taxon table (`taxon = NULL`) the lineage
is the aphiaid alone. The rank columns and the name are taken once per
aphiaid (`MIN`, so a NULL class is replaced by a named one if both
occur); `records` is summed over the coarsest `occ_h3` tier.

## Examples

``` r
cat(obis_h3_species_lookup_sql())
#> WITH RECURSIVE sp AS (
#>   SELECT aphiaid::BIGINT AS aphiaid, MIN(species) AS species, MIN(genus) AS genus,
#>          MIN(family) AS family, MIN("order") AS "order", MIN(class) AS class,
#>          MIN(phylum) AS phylum, SUM(records)::BIGINT AS records
#>   FROM occ_h3
#>   WHERE res = (SELECT MIN(res) FROM occ_h3) AND aphiaid IS NOT NULL
#>   GROUP BY 1),
#> up AS (
#>   SELECT aphiaid, aphiaid AS node, 0 AS depth FROM sp
#>   UNION ALL
#>   SELECT up.aphiaid, t.parentNameUsageID::BIGINT AS node, up.depth + 1 AS depth
#>   FROM up JOIN taxon t ON t.taxonID = up.node
#>   WHERE t.parentNameUsageID IS NOT NULL AND t.parentNameUsageID <> t.taxonID
#>     AND up.depth < 64),
#> lin AS (SELECT aphiaid, list(node ORDER BY depth)::BIGINT[] AS lineage FROM up GROUP BY aphiaid)
#> SELECT sp.aphiaid, (dense_rank() OVER (ORDER BY sp.species))::INTEGER AS name_key,
#>        sp.species, sp.genus, sp.family, sp."order", sp.class, sp.phylum,
#>        lin.lineage, sp.records
#> FROM sp JOIN lin USING (aphiaid)
#> ORDER BY sp.aphiaid
```
