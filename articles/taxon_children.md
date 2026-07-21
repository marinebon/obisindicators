# Children taxa & an effort proxy (SPUE) from the OBIS snapshot

This article shows how to filter OBIS by **any WoRMS taxon, at any
rank**, using only the local OBIS snapshot — no calls to the (heavy)
OBIS web services — and how to turn a higher-order taxon into an
**observation-effort proxy** for a presence-only
sightings-per-unit-effort (SPUE) indicator.

It builds on
[`vignette("h3t")`](https://marinebon.org/obisindicators/articles/h3t.md):
the same `occ_h3` species-level store, plus a baked **`taxon`** table
(the WoRMS taxonomy) that lets us resolve the descendants of an
arbitrary AphiaID.

## Why a `taxon` table?

`occ_h3` carries only the six Darwin Core rank columns (`phylum` …
`species`) plus the species-level `aphiaid`. That is enough to filter
on, say, `class = "Aves"`, but **not** on a rank that isn’t a column —
e.g. Infraorder *Cetacea*, or an arbitrary clade referenced only by its
AphiaID. To support those we walk the full WoRMS hierarchy:

- `build_taxon_parquet.R` extracts `taxonID` (= AphiaID),
  `parentNameUsageID`, `acceptedNameUsageID`, `scientificName`,
  `taxonRank` from a WoRMS DarwinCore `taxon.txt` into a compact
  `taxon.parquet`.
- `migrate_add_taxon.R` bakes that into `obis_h3.duckdb` (indexed on
  `parentNameUsageID`), alongside `occ_h3` / `idx_h3`.

``` r

library(obisindicators)
```

``` r

library(DBI)
library(duckdb)

con <- dbConnect(duckdb(), "/share/data/obis/obis_h3.duckdb", read_only = TRUE)
dbExecute(con, "LOAD h3;")
```

## Resolve the children of a taxon

[`obis_taxon_children()`](https://marinebon.org/obisindicators/reference/obis_taxon_children.md)
returns the seed taxon plus every descendant, at any rank, via a
recursive walk of `parentNameUsageID`. On the full WoRMS table (~1.5 M
rows) this resolves in a fraction of a second.

``` r

# Infraorder Cetacea = AphiaID 2688 (a rank that is NOT an occ_h3 column)
cet <- obis_taxon_children(2688, con)
nrow(cet)                              # ~1,665 descendant taxa
table(cet$taxonRank)                   # Species, Genus, Family, ...

# Matt Biddle's phytoplankton example: class Bacillariophyceae (diatoms) = 148899
dia <- obis_taxon_children(148899, con)
nrow(dia)                              # ~71,500 descendant taxa
```

The descendant AphiaIDs (`cet$taxonID`) are exactly the set used to
filter `occ_h3.aphiaid`.
[`obis_taxon_subtree_sql()`](https://marinebon.org/obisindicators/reference/obis_taxon_subtree_sql.md)
returns that resolution as a standalone read-only `SELECT`, handy for
the API.

## Map a taxon’s records (any rank)

`obis_h3t_sql(aphiaid = ...)` builds a served tile query that filters
`occ_h3` to the subtree via a recursive CTE (the `h3t` validator permits
`WITH RECURSIVE`).
[`obis_h3t_url()`](https://marinebon.org/obisindicators/reference/obis_h3t_url.md)
base64-encodes it into a tile URL.

``` r

sql <- obis_h3t_sql(indicator = "n", aphiaid = 2688)   # # records, all Cetacea
cat(sql)
#> WITH RECURSIVE taxon_tree AS (
#> SELECT taxonID, parentNameUsageID
#> FROM taxon
#> WHERE taxonID IN (2688)
#> UNION ALL
#> SELECT t.taxonID, t.parentNameUsageID
#> FROM taxon t
#> JOIN taxon_tree tt ON t.parentNameUsageID = tt.taxonID
#> WHERE t.parentNameUsageID IS NOT NULL), src AS (
#>   SELECT CAST(h3_cell_to_parent(cell_id, LEAST({{res}}, 7)) AS BIGINT) AS cell_id,
#>          species, SUM(records) AS ni
#>   FROM occ_h3
#>   WHERE res = CASE WHEN LEAST({{res}}, 7) <= 3 THEN 3 WHEN LEAST({{res}}, 7) <= 5 THEN 5 ELSE 7 END
#>     AND aphiaid IN (SELECT taxonID FROM taxon_tree)
#>   GROUP BY 1, 2)
#> SELECT cell_id, SUM(ni) AS value, SUM(ni) AS n FROM src GROUP BY cell_id

url <- obis_h3t_url(
  base_url  = "h3tiles://h3t.marinesensitivity.org/h3t/{z}/{x}/{y}.h3t",
  sql       = sql)
```

``` r

library(mapgl)
maplibre(center = c(-40, 20), zoom = 1.5) |>
  add_h3t_source(id = "cet", tiles = url) |>
  add_fill_layer(
    id = "cet_fill", source = "cet", source_layer = "cet",
    fill_color = interpolate(
      column = "value", values = c(1, 1000),
      stops  = c("#3b528b", "#5ec962")))
```

## An effort proxy: sightings per unit effort (SPUE)

A raw record map conflates *abundance* with *observation effort* — a
hexagon lights up both where a species is common and where people looked
hard. When records come from multi-species surveys, a **higher-order
taxon** gives a presence-only proxy for that effort: within the
footprint of, say, all Cetacea (the surveys that could have recorded any
whale/dolphin), what fraction of records are the target species?

``` math
\text{SPUE}_{cell} = \frac{\text{records of the target taxon}}{\text{records of the effort taxon}}
```

[`obis_spue_sql()`](https://marinebon.org/obisindicators/reference/obis_spue_sql.md)
builds this as a served tile query (two recursive subtrees: numerator =
target, denominator = effort).
[`calc_spue()`](https://marinebon.org/obisindicators/reference/calc_spue.md)
is the pinned R reference (see `test-spue-parity.R`).

``` r

# target: Tursiops truncatus (common bottlenose dolphin) = 137111
# effort: Infraorder Cetacea = 2688 (its multi-species-survey footprint)
spue_sql <- obis_spue_sql(num_aphiaid = 137111, den_aphiaid = 2688)
cat(spue_sql)
#> WITH RECURSIVE num_tree AS (
#> SELECT taxonID, parentNameUsageID
#> FROM taxon
#> WHERE taxonID IN (137111)
#> UNION ALL
#> SELECT t.taxonID, t.parentNameUsageID
#> FROM taxon t
#> JOIN num_tree tt ON t.parentNameUsageID = tt.taxonID
#> WHERE t.parentNameUsageID IS NOT NULL),
#> den_tree AS (
#> SELECT taxonID, parentNameUsageID
#> FROM taxon
#> WHERE taxonID IN (2688)
#> UNION ALL
#> SELECT t.taxonID, t.parentNameUsageID
#> FROM taxon t
#> JOIN den_tree tt ON t.parentNameUsageID = tt.taxonID
#> WHERE t.parentNameUsageID IS NOT NULL),
#> src AS (
#>   SELECT CAST(h3_cell_to_parent(cell_id, LEAST({{res}}, 7)) AS BIGINT) AS cell_id,
#>          -- COALESCE so an effort cell lacking the target reads 0, not NULL
#>          -- (matches calc_spue(): sum of no records is 0). presence-only:
#>          -- the target was absent *despite* effort here.
#>          COALESCE(SUM(records) FILTER (WHERE aphiaid IN (SELECT taxonID FROM num_tree)), 0) AS n_num,
#>          SUM(records) AS n_den
#>   FROM occ_h3
#>   WHERE res = CASE WHEN LEAST({{res}}, 7) <= 3 THEN 3 WHEN LEAST({{res}}, 7) <= 5 THEN 5 ELSE 7 END
#>     AND aphiaid IN (SELECT taxonID FROM den_tree)
#>   GROUP BY 1)
#> SELECT cell_id,
#>        n_num::DOUBLE / NULLIF(n_den, 0) AS value,
#>        n_den AS n
#> FROM src

spue_url <- obis_h3t_url(
  base_url = "h3tiles://h3t.marinesensitivity.org/h3t/{z}/{x}/{y}.h3t",
  sql      = spue_sql)
```

``` r

maplibre(center = c(-40, 20), zoom = 1.5) |>
  add_h3t_source(id = "spue", tiles = spue_url) |>
  add_fill_layer(
    id = "spue_fill", source = "spue", source_layer = "spue",
    fill_color = interpolate(
      column = "value", values = c(0, 1),
      stops  = c("#440154", "#fde725")))
```

The tooltip `n` carries the **effort** count (denominator): a bright
cell backed by a large `n` is a robust SPUE; a bright cell over `n = 3`
is noise. Choosing the effort taxon is the analyst’s call — the parent
class or order is a sensible default, but a survey-defined group
(e.g. Cetacea, seabirds) is often better. See
[`vignette("scaling")`](https://marinebon.org/obisindicators/articles/scaling.md)
for how the denominator’s sparsity behaves across H3 resolutions.

``` r

dbDisconnect(con, shutdown = TRUE)
```
