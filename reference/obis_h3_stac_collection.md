# Write the STAC Collection of an obis-h3 release

Reads a release's `release.json` (from
[`obis_h3_export_parquet()`](https://marinebon.org/obisindicators/reference/obis_h3_export_parquet.md))
and writes `collection.json`, a STAC Collection for the Ocean Metrics
`h3` profile 1.1 (`platform/packages/catalog/schemas/h3.schema.json`),
plus one STAC Item per map layer under `items/` (`all` and each EOV),
with the hooks the atlas reads:

## Usage

``` r
obis_h3_stac_collection(
  release_dir,
  file = file.path(release_dir, "collection.json"),
  id = "obis_h3",
  items = TRUE
)
```

## Arguments

- release_dir:

  the release directory (holding `release.json`).

- file:

  output file (default `collection.json` in `release_dir`).

- id:

  the collection id (default `"obis_h3"`, the id the atlas's
  `?c=obis_h3` names).

- items:

  write the Items under `release_dir/items/` and link them (default
  TRUE).

## Value

invisibly, the paths written (the collection, then the Items).

## Details

- `h3:resolutions`, `h3:layout` (the `all` layer's template, its parent
  splits and `row_group_rows`, the largest row group of a cell-sorted
  file), `table:columns`;

- `h3:periods`, a list of two period sets, decades and years, each with
  its values, placeholder, resolutions and template;

- `h3:species_table` (template, resolutions, class partitions, sort,
  columns with `name_key`, `year_min`, `year_max` and the decade
  variant's `period`, lookup, heads) and `h3:heads` (the heads are
  `taxon` layers);

- `cube:dimensions`: `layer` (`all` and the EOVs, one Item each),
  `indicator` (the five columns), `period` (`all`, the decades as
  `<yyy0>s`, the years as `<yyyy>`) and `res`; `atlas:metric` (the
  default indicator, `es`);

- `item_assets` (each Item's `data`, `decade` and `year` assets: a layer
  folder and the path template under it);

- the assets `stats` (the legend's source: p02 to p98 per layer, key,
  period, res and variable), `taxon_groups` (the taxa and heads to
  search, with their paths), `files`, `release`, the species lookup, the
  heads list and `species_flat`.

Every href is relative to the release folder;
[`obis_h3_stac_stable()`](https://marinebon.org/obisindicators/reference/obis_h3_stac_stable.md)
makes the copy with absolute hrefs that lives at a stable url. The other
layers (taxon, decade, year, species) stay listed under `obis:layers`
and `obis:species`.
