# Look up WoRMS taxon records by AphiaID

Batched, parallel calls to the WoRMS REST `AphiaRecordsByAphiaIDs`
operation, returning exactly the columns the baked `taxon` table
carries. This is the per-id supplement to the bulk `taxon.txt` download
— see
[`obis_taxon_fill_gaps()`](https://marinebon.org/obisindicators/reference/obis_taxon_fill_gaps.md),
which drives it.

## Usage

``` r
wm_aphia_records(
  aphiaid,
  server = WORMS_REST_SERVER,
  batch_size = WM_MAX_IDS,
  concurrency = 4L,
  verbose = TRUE
)
```

## Arguments

- aphiaid:

  integer WoRMS AphiaID(s) to look up.

- server:

  WoRMS REST base URL; default `"https://www.marinespecies.org/rest"`.

- batch_size:

  ids per request (WoRMS caps this operation at 50).

- concurrency:

  max parallel requests; kept low by default to stay polite to a shared
  public service.

- verbose:

  message progress per round of requests.

## Value

data frame with `taxonID`, `parentNameUsageID`, `acceptedNameUsageID`,
`scientificName`, `taxonRank`, `taxonomicStatus`; zero rows if nothing
matched.

## Details

Ids WoRMS has no record for are simply absent from the result (the API
returns a positional `null` for them, or HTTP 204 when a whole batch
misses), so `setdiff(aphiaid, out$taxonID)` gives the unresolvable ids.
