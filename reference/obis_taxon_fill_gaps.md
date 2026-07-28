# Fill gaps in the `taxon` table from the WoRMS REST API

Supplements the bulk WoRMS `taxon.txt` download with per-id lookups for
every AphiaID that `occ_h3` carries but `taxon` lacks, then keeps going
until the tree is *closed*: each round also fetches any ancestor newly
referenced by the rows just inserted. Without that closure an orphan
species stays disconnected from its seed and remains unreachable by
[`obis_taxon_children()`](https://marinebon.org/obisindicators/reference/obis_taxon_children.md).

## Usage

``` r
obis_taxon_fill_gaps(
  con,
  fetch = wm_aphia_records,
  max_rounds = 40L,
  min_records = 0L,
  verbose = TRUE
)
```

## Arguments

- con:

  a `DBI` connection to a **writable** store with `occ_h3` + `taxon`.

- fetch:

  function taking an integer vector of AphiaIDs and returning a data
  frame shaped like
  [`wm_aphia_records()`](https://marinebon.org/obisindicators/reference/wm_aphia_records.md)'s
  output; the seam that lets tests run without network.

- max_rounds:

  runaway guard on closure rounds. Each round climbs exactly one
  generation, and a full WoRMS chain (every intermediate rank from
  species to Biota) runs ~15-20 deep, so this needs headroom well past
  the depth of the *named* ranks. If the guard is hit while ancestors
  are still missing the fill warns and reports `closed = FALSE` rather
  than leaving you to believe the tree is whole.

- min_records:

  only chase orphans with at least this many records.

- verbose:

  message per-round progress.

## Value

invisibly, a list with `added` (data frame of inserted rows),
`unresolved` (AphiaIDs WoRMS had no record for), `rounds`,
`records_recovered` (occurrence records made reachable by the fill), and
`closed` (did the ancestor walk reach closure within `max_rounds`).

## Details

Writes to `con`, so open the store read-write (see
`data-raw/migrate_fill_taxon_gaps.R`, which copies first).
