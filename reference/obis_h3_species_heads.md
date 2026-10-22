# The pre-aggregated heads the species table still needs

A subtree inside one class reads one class file of the species table
plus the `_none` file; a taxon spanning several classes reads them all,
which for Animalia at res 4 is slower than h3t (spike 2, 2026-10-22).
Those taxa get a pre-aggregated head (an indicator layer like `all`):
the release already has the heads all, EOV and phylum to family (the
`taxon` layer); this lists the ones to add, Animalia (aphiaid 2) and
every taxon whose subtree spans two or more *named* classes (the
lookup's `class`, NULLs not counted). Only taxa that occur in some
lineage are listed.

## Usage

``` r
obis_h3_species_heads(
  con,
  lookup = "species_lookup",
  taxon = "taxon",
  min_classes = 2L,
  include = 2L
)
```

## Arguments

- con:

  a DBI connection.

- lookup:

  the table (or a parenthesised SELECT) with the lookup rows of
  [`obis_h3_species_lookup_sql()`](https://marinebon.org/obisindicators/reference/obis_h3_species_lookup_sql.md).

- taxon:

  the WoRMS taxon table for names and ranks (NULL: no names).

- min_classes:

  the number of named classes that makes a head (default 2).

- include:

  aphiaids always listed when present (default 2, Animalia).

## Value

a data frame ordered by aphiaid: `aphiaid, name, rank, n_classes` (named
classes spanned), `n_species` (aphiaids in the subtree), `records`,
`reason` (`"included"` for `include`, else `"multi_class"`).
