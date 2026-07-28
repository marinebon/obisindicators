# AphiaIDs present in `occ_h3` but missing from the `taxon` table

The reachability gap: these occurrences cannot be found by any
[`obis_taxon_children()`](https://marinebon.org/obisindicators/reference/obis_taxon_children.md)
walk, so they are silently excluded from every `aphiaid`-filtered
indicator, EOV and SPUE query. Feed the result to
[`obis_taxon_fill_gaps()`](https://marinebon.org/obisindicators/reference/obis_taxon_fill_gaps.md).

## Usage

``` r
obis_taxon_orphans(con, min_records = 0L)
```

## Arguments

- con:

  a `DBI` connection to a store with `occ_h3` and `taxon`.

- min_records:

  only report orphans with at least this many records.

## Value

data frame of `taxonID` and `records`, most records first.
