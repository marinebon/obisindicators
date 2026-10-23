# Write the stable-url copy of an obis-h3 release's STAC Collection

The atlas links one collection url that survives a monthly release:
`obis-h3/collection.json`, next to `latest.json`. This writes it from
the release's own `collection.json`
([`obis_h3_stac_collection()`](https://marinebon.org/obisindicators/reference/obis_h3_stac_collection.md))
with every relative href and path template made absolute under
`base_url` (the release folder, e.g.
`https://s3.us-east-1.amazonaws.com/oceanmetrics.io-public/obis-h3/v20261012/`):
the links (Items included), the assets, `h3:layout`, `h3:periods`
templates, `h3:species_table` (its template, lookup and heads),
`h3:heads` and the `obis:layers` templates. Its `self` link is
`self_url`. The Items stay in the release folder, where their own
relative hrefs resolve.

## Usage

``` r
obis_h3_stac_stable(
  release_dir,
  base_url,
  file = file.path(dirname(normalizePath(release_dir)), "collection.json"),
  self_url = NULL
)
```

## Arguments

- release_dir:

  the release directory (holding `collection.json`).

- base_url:

  the release folder's public url, ending in `/`.

- file:

  output file (default `collection.json` in the parent of
  `release_dir`).

- self_url:

  the stable url of the file (default `base_url`'s parent plus
  `collection.json`).

## Value

invisibly, the path written.
