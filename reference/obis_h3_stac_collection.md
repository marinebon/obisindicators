# Write the STAC Collection of an obis-h3 release

Reads a release's `release.json` (from
[`obis_h3_export_parquet()`](https://marinebon.org/obisindicators/reference/obis_h3_export_parquet.md))
and writes `collection.json`, a STAC Collection for the Ocean Metrics
`h3` profile (`platform/packages/catalog/schemas/h3.schema.json`): the
resolutions, the `all` layer's path template with its parent splits
(`h3:layout`), the indicator columns (`table:columns`) and, when the
release has one, the species table (`h3:species_table`: its template,
resolutions, class partitions, sort, columns and lookup). The profile's
fields describe the `all` layer; the other layers (EOV, taxon, decade,
year) and the heads list are in pass-through keys, `obis:layers` (each
with a `{key}` template, and `h3:periods` for the decade and year
layers) and `obis:species` (`name_key`, `null_class`, `heads`), which
the profile allows.

## Usage

``` r
obis_h3_stac_collection(
  release_dir,
  file = file.path(release_dir, "collection.json"),
  id = "obis-h3"
)
```

## Arguments

- release_dir:

  the release directory (holding `release.json`).

- file:

  output file (default `collection.json` in `release_dir`).

- id:

  the collection id (default `"obis-h3"`).

## Value

invisibly, the path written.
