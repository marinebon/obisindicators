# Standalone SQL for the AphiaID subtree (descendant taxonIDs)

Wraps
[`obis_taxon_children()`](http://marinebon.org/obisindicators/reference/obis_taxon_children.md)'s
recursive walk as a self-contained read-only `SELECT` returning the
distinct descendant `taxonID`s. Handy for the API and for composing an
`aphiaid IN (...)` filter.

## Usage

``` r
obis_taxon_subtree_sql(aphiaid)
```

## Arguments

- aphiaid:

  one or more integer WoRMS AphiaID(s).

## Value

a SQL string:
`WITH RECURSIVE taxon_tree AS (...) SELECT DISTINCT taxonID ...`.
