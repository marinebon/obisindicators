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
  max_passes = 3L,
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

- max_passes:

  retry passes over batches whose request failed, with a linear backoff
  between them.

- verbose:

  message progress per round of requests.

## Value

data frame with `taxonID`, `parentNameUsageID`, `acceptedNameUsageID`,
`scientificName`, `taxonRank`, `taxonomicStatus`; zero rows if nothing
matched. The `"failed_ids"` attribute holds ids whose request never
succeeded (distinct from ids WoRMS genuinely lacks).

## Details

A request that FAILS is not the same as an id WoRMS has no record for,
and the two must not be conflated: an id is only unresolvable if a
*successful* response omitted it (the API returns a positional `null`
for those, or HTTP 204 when a whole batch misses). Batches whose request
errored are retried up to `max_passes` times, and any still failing are
returned in the `"failed_ids"` attribute so the caller can retry rather
than write them off. Conflating the two silently discarded 2,250
resolvable algae ids (exactly 45 whole batches) on the first real run
against the global store.
