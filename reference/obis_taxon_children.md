# Resolve the descendant taxa of a WoRMS AphiaID

Recursively walks the WoRMS `taxon` table (baked into the obis_h3 DuckDB
store) down `parentNameUsageID` to return the seed taxon plus every
descendant, at any rank. This is the local-snapshot replacement for the
heavy OBIS `taxonid=` service queries: given e.g. Infraorder Cetacea's
AphiaID it returns all its species, whose AphiaIDs then filter `occ_h3`.

## Usage

``` r
obis_taxon_children(aphiaid, con)
```

## Arguments

- aphiaid:

  one or more integer WoRMS AphiaID(s) (`taxonID`) to root the subtree
  at.

- con:

  a `DBI` connection to a DuckDB store exposing a `taxon` table with
  columns `taxonID`, `parentNameUsageID`, `acceptedNameUsageID`,
  `scientificName`, `taxonRank`.

## Value

data frame with one row per taxon in the subtree: `taxonID`,
`parentNameUsageID`, `acceptedNameUsageID`, `scientificName`,
`taxonRank`, and `depth_level` (0 for the seed, incremented per
generation).
