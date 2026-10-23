# Export an obis_h3 store to hive-partitioned Parquet

Writes the indicator layers of a store built by
[`build_obis_h3_duckdb()`](https://marinebon.org/obisindicators/reference/build_obis_h3_duckdb.md)
to a directory of hive-partitioned Parquet files that a static web app
can read directly with DuckDB-WASM (one small file per map layer and H3
resolution):

## Usage

``` r
obis_h3_export_parquet(
  con,
  dir_out,
  release,
  res_decade = 1:5,
  res_year = 1:5,
  years = NULL,
  res_species = c(3L, 4L, 5L),
  species_decades = TRUE,
  res_species_decade = c(3L, 4L),
  res_species_flat = 3L,
  heads = TRUE,
  res_heads = 1:7,
  parent_res = c(`6` = 2L, `7` = 3L),
  parent_res_taxon = c(`6` = 0L, `7` = 0L),
  parent_min_rows = 50000,
  max_open = EXPORT_MAX_OPEN,
  compression = "zstd",
  row_group_rows = 10000L,
  overwrite = FALSE,
  decades = seq(1960L, 2020L, by = 10L),
  esn = 50L,
  place_collections = NULL,
  place_exact = NULL,
  place_exact_occ = NULL,
  temp_dir = NULL,
  max_temp_dir_size = NULL,
  memory_limit = NULL,
  threads = NULL,
  verbose = TRUE
)
```

## Arguments

- con:

  connection from
  [`obis_store_connect()`](https://marinebon.org/obisindicators/reference/obis_store_connect.md)
  (read-only is fine).

- dir_out:

  output directory; files go under `dir_out/release/`.

- release:

  release tag, e.g. `"v20260728"` (the date of the OBIS sync the store
  was built from); recorded in `release.json`. Its `obis_snapshot` is
  the environment variable `OBIS_DATA_DATE` (the newest OBIS object's
  date, which `refresh_obis_h3.sh` passes) when that is a `YYYY-MM-DD`
  date, else the date in the tag.

- res_decade:

  H3 resolutions for the decade layers (default 1-5).

- res_year:

  H3 resolutions for the year layers (default 1-5); `integer(0)` skips
  them.

- years:

  years to export in the year layers; default NULL, every year present.

- res_species:

  H3 resolutions of the species table (default 3, 4, 5); `integer(0)`
  skips it.

- species_decades:

  also write the per-decade species table `species_decade/` (default
  TRUE, 0.11.0), at `res_species_decade`.

- res_species_decade:

  the resolutions of the per-decade species table (default 3 and 4: the
  decade filter on a WoRMS subtree).

- res_species_flat:

  the resolutions of the unpartitioned species table
  `species_flat/res=<r>.parquet` (default 3: the cell query);
  `integer(0)` skips it.

- heads:

  write the pre-aggregated heads as taxon layers (default TRUE; needs
  the species table and the store's `taxon` table).

- res_heads:

  the resolutions of the heads (default 1-7; res 6 and 7 are split by
  `parent_res_taxon` like the rank layers).

- parent_res:

  named integer vector, fine resolution -\> parent resolution, for the
  `all` and `eov` layers: those resolutions are written one file per
  parent cell (`res=<r>/p=<parent>/`). Default `c("6" = 2L, "7" = 3L)`;
  `NULL` writes every resolution whole.

- parent_res_taxon:

  the same for the taxon layer (default `c("6" = 0L, "7" = 0L)`, the
  base cell).

- parent_min_rows:

  a (layer key, res) with at most this many rows is written whole even
  when its res is in `parent_res` (default 50000).

- max_open:

  no longer used (0.11.0): every file is written by its own `COPY`, so
  no more than one is open at a time. Kept so old calls still run.

- compression:

  Parquet compression codec (default `"zstd"`).

- row_group_rows:

  rows per Parquet row group of the indicator layer files (default
  10000; DuckDB rounds up to a multiple of 2048, so a group holds at
  most 10,240). Recorded in `release.json` (`row_group_rows`, and the
  largest group written as `row_group_rows_max`).

- overwrite:

  replace an existing `dir_out/release/` (default FALSE: stop).

- decades:

  decades (first year) to export in the decade layers; default
  1960-2020. NULL exports every decade present.

- esn:

  expected sample size for ES(n) in the decade layers; default 50 (as in
  the store).

- place_collections:

  optional named list (or character vector), slug = the gazetteer
  collection's membership (a directory or URL, its `membership.json`, or
  anything
  [`obis_place_indicators()`](https://marinebon.org/obisindicators/reference/obis_place_indicators.md)
  takes as `membership`), e.g. `list(eez = "<gazetteer base>/eez")`.
  Default `NULL`: no place layer.

- place_exact:

  optional named list (or character vector), slug = the path of the
  collection's GeoParquet of polygons (`place_id`, WKB `geometry`, an
  optional `area_km2`), e.g.
  `list(mr_eez = "<places-internal>/mr_eez/places.parquet")`. Default
  `NULL`: no exact place layer. Needs `place_exact_occ`.

- place_exact_occ:

  the occurrence parquet path(s)/glob(s) the exact place indicators are
  computed from (OBIS open data, nested or flat; see
  [`obis_place_indicators_exact()`](https://marinebon.org/obisindicators/reference/obis_place_indicators_exact.md)).

- temp_dir, max_temp_dir_size:

  DuckDB spill directory and cap for the exact place computation (it
  runs in its own DuckDB instance with this `memory_limit` and
  `threads`).

- memory_limit:

  optional DuckDB `memory_limit` (e.g. `"24GB"`).

- threads:

  optional DuckDB thread count (e.g. `8`).

- verbose:

  print progress and the summary (default TRUE).

## Value

invisibly, a character vector of the files written (absolute paths).

## Details

    <dir_out>/<release>/
      release.json                              build metadata, row counts, layout, columns, file manifest
      all/res=<1..5>/data_0.parquet             idx_h3 (all taxa, all years)
      all/res=<6,7>/p=<parent>/data_0.parquet   the fine res, one file per parent cell
      eov/eov=<eov>/res=<r>/data_0.parquet      idx_h3_eov
      taxon/rank=<rank>/taxon=<taxon>/res=<r>/  idx_h3_taxon (phylum / class / order / family),
                                                plus the heads (kingdom, subphylum, superclass ...)
      decade/all/decade=<yyy0>/res=<r>/         per decade, all taxa  (res in res_decade)
      decade/eov/eov=<eov>/decade=<yyy0>/res=<r>/  per decade and EOV (res in res_decade)
      year/all/year=<yyyy>/res=<r>/             per year, all taxa    (res in res_year)
      year/eov/eov=<eov>/year=<yyyy>/res=<r>/   per year and EOV      (res in res_year)
      species/res=<r>/class=<class>/data_0.parquet  species x hex x count (res in res_species)
      species/species.parquet                   the species lookup: names, name_key, lineage
      species/heads.json                        the pre-aggregated heads and the layer serving each
      species_decade/res=<r>/decade=<d>/class=<class>/  per decade (res in res_species_decade)
      species_flat/res=<r>.parquet              one cell-sorted file, every class (res_species_flat)
      place/coll=<slug>/data_0.parquet          per-place pooled indicators (only with place_collections)
      place_exact/coll=<slug>/indicators.parquet, years.parquet, meta.json
                                                exact point-in-polygon indicators (only with place_exact)
      collection.json                           STAC Collection (h3 profile), obis_h3_stac_collection()
      stats.parquet                             value ranges per layer x key x period x res x variable
      taxon_groups.parquet                      the taxa and EOVs available, with totals and paths
      files.parquet                             manifest: layer, path, url_path, rows, bytes per file

Every indicator file has the columns `h3` (lowercase hex string),
`cell_id`, `n`, `sp`, `shannon`, `simpson`, `es`; the partition keys
live in the path (read with `hive_partitioning = true`). Its rows are
sorted by `cell_id` in row groups of `row_group_rows` (about 10k), so a
reader that knows the cells under a tile reads only the row groups whose
`cell_id` statistics overlap them (a range read) instead of the whole
file. Each file is written by its own `COPY`
([`obis_h3_write_partitions()`](https://marinebon.org/obisindicators/reference/obis_h3_write_partitions.md)),
since DuckDB's `PARTITION_BY` does not keep the order. The decade layers
are computed from `occ_h3` with the same SQL builder as `idx_h3` /
`idx_h3_eov` (so the math is identical to the store): `n` = records,
`sp` = distinct species, Shannon, Simpson and ES(`esn`), grouped by cell
and `decade = floor(date_year / 10) * 10`; records without a year are
left out of the decade layers. EOV membership is the store's `eov` table
(`occ_h3.aphiaid = eov.taxonID`), as in
[`obis_eov_bake()`](https://marinebon.org/obisindicators/reference/obis_eov_bake.md).
Layers whose source tables are missing (e.g. no `idx_h3_eov` in a store
without taxonomy) are skipped with a message.

Partition values are percent-encoded by DuckDB (a space becomes `%20`),
and DuckDB decodes them on read. A static web server decodes the URL
once, so a browser must request the on-disk name with `%` itself encoded
(`%2520`); `taxon_groups.parquet` carries both `path` (on disk) and
`url_path` (to fetch), and `files.parquet` lists every file with both
forms. Each partition is exactly one `data_0.parquet`.

**Parent partitions for the fine resolutions.** A whole res-7 layer is
tens of MB, too much for a browser to load at once, so the resolutions
named in `parent_res` are split by parent cell: every row of
`all/res=7/` goes to
`all/res=7/p=<h3 of its res-3 parent>/data_0.parquet` (default res 6 by
its res-2 parent, res 7 by its res-3 parent), and a viewer loads only
the parent cells that cover its viewport. The taxon layer uses
`parent_res_taxon` (default the res-0 base cell: res-3 parents would
make over a million files across ~5k taxa). A (layer key, res) with at
most `parent_min_rows` rows stays one whole file, since splitting it
would only add requests. The decade layers are never split (their
default resolutions are 1-5). `files.parquet` has a `parent` column (the
partition's parent cell, NULL for a whole file; its resolution is the
parent resolution), and each layer in `release.json` lists the
`parent_res` actually used.

**Place layer (optional).** With `place_collections`, each gazetteer
collection gets one file, `place/coll=<slug>/data_0.parquet`, with the
indicators of every place pooled from its res-7 member cells, records
weighted by each cell's share of area inside the place
([`obis_place_indicators()`](https://marinebon.org/obisindicators/reference/obis_place_indicators.md)):
columns `place_id`, `layer` (`all` \| `eov`), `key` (” or the EOV),
`decade` (NULL = all years, else the decades above), `n` (fractional),
`sp`, `shannon`, `simpson`, `es`, `cells`, `area`. These are true
per-place indices of the pooled, area-weighted counts, not means of
hexagon values. The files are listed in `files.parquet` (layer `place`)
and `release.json` (`layers$place`, with each collection's membership
version); `stats.parquet` does not cover them.

**Exact place layer (optional).** With `place_exact`, each polygon
collection gets `place_exact/coll=<slug>/indicators.parquet` and
`years.parquet`
([`obis_place_indicators_exact()`](https://marinebon.org/obisindicators/reference/obis_place_indicators_exact.md),
written by
[`obis_place_exact_write()`](https://marinebon.org/obisindicators/reference/obis_place_exact_write.md)):
the indicators of every place computed from the OBIS occurrences inside
the true polygon, with no H3 approximation, per EOV (`all` and the
store's `eov` table), per decade and per year, with Berger-Parker and
density. They are values only (no geometry), computed from the
occurrence parquet files `place_exact_occ` (the local snapshot the store
was built from), which takes far longer than the layers above. The files
are listed in `files.parquet` (layer `place_exact`) and `release.json`
(`layers$place_exact`, with each collection's places and record totals);
`stats.parquet` does not cover them.

**Year layers.** `year/all` and `year/eov` are the decade layers per
year: the same SQL
([`obis_h3_year_sql()`](https://marinebon.org/obisindicators/reference/obis_h3_year_sql.md))
grouped by `year = date_year`, one partition per year present from
`min(date_year)` to `max(date_year)` (or the `years` asked for), at the
resolutions `res_year` (default 1-5, never split by parent).
`release.json` lists the years written (`years`).

**The species table** (`species/`, spike 2 of the Ocean Metrics
restructure): one row per (cell, aphiaid) with `n` = records, at the
resolutions `res_species` (default 3, 4, 5; res 4 rolled up from the
res-5 tier), so a browser answers a WoRMS subtree or "which species are
in this cell" from static files. Columns
`h3, cell_id, name_key, aphiaid, n`
([`obis_h3_species_sql()`](https://marinebon.org/obisindicators/reference/obis_h3_species_sql.md));
one `data_0.parquet` per (res, class) written by
[`obis_h3_write_partitions()`](https://marinebon.org/obisindicators/reference/obis_h3_write_partitions.md),
sorted by `cell_id, aphiaid` in row groups of 100k; a NULL class is
`class=_none`. `species/species.parquet`
([`obis_h3_species_lookup_sql()`](https://marinebon.org/obisindicators/reference/obis_h3_species_lookup_sql.md))
has one row per aphiaid with its names, a `name_key` per distinct name
(richness counts names) and its `lineage` (self, then ancestors up the
store's `taxon` table); a subtree is `list_contains(lineage, <aphiaid>)`
([`obis_h3_species_subtree_sql()`](https://marinebon.org/obisindicators/reference/obis_h3_species_subtree_sql.md)).
`species/heads.json` lists the taxa that need a pre-aggregated head
([`obis_h3_species_heads()`](https://marinebon.org/obisindicators/reference/obis_h3_species_heads.md):
Animalia and every taxon spanning two or more named classes) and the
layer that serves each. Each species row also carries `year_min` and
`year_max`, the first and last year the aphiaid was recorded in the cell
(within the decade in `species_decade/`), for the Cell pane.
`species_flat/res=<r>.parquet` (default res 3) is the same table in one
file for every class, sorted by `cell_id, aphiaid` in row groups of
`row_group_rows`, so the species of one cell are a range read of one
file (spike 2: 0.53 MB for a res-1 cell) instead of one row group per
class file.

**The heads** (`heads = TRUE`) are written as ordinary taxon layers,
`taxon/rank=<rank>/taxon=<name>/res=<r>/` at `res_heads`
([`obis_h3_heads_sql()`](https://marinebon.org/obisindicators/reference/obis_h3_heads_sql.md):
the WoRMS subtree from the lineage, species counted by `name_key`, so a
head equals
[`obis_h3_species_subtree_sql()`](https://marinebon.org/obisindicators/reference/obis_h3_species_subtree_sql.md)
cell for cell), where `rank` is the WoRMS rank lowercased without a
botanical alias ("Phylum (Division)" is `phylum`). They then appear in
`stats.parquet`, `taxon_groups.parquet` and `files.parquet` as any
taxon. A head is not written when a layer already serves it: one whose
subtree holds every aphiaid (and the store has no record without one) is
the `all` layer; one whose rank and name are a rank layer of
`idx_h3_taxon` keeps that layer (built from the OBIS rank column, not
the WoRMS subtree, so it may differ in a few cells). `heads.json` gives
each head's `served_by` (`head`, `all`, `rank_layer`, or `homonym` for a
second taxon with the same rank and name) and its `layer`. The
per-decade variant `species_decade/` is written only with
`species_decades = TRUE`. Rows with no aphiaid are left out; a store
without one (e.g. the demo store built from `occ_SAtlantic`) gets no
species layer.

`collection.json` is a STAC Collection of the release for the Ocean
Metrics `h3` profile
([`obis_h3_stac_collection()`](https://marinebon.org/obisindicators/reference/obis_h3_stac_collection.md)).

`stats.parquet` has one row per indicator layer and (`key`, `decade`,
`year`, `res`, `variable`) with `min`, `p02`, `p50`, `p98`, `max` and
`n_cells` (cells with a non-NULL value; a variable NULL everywhere in a
partition gets a row with NULL ranges and `n_cells` 0), for colour
ramps. `key` is the EOV or taxon name (” for the all-taxa layers),
`rank` the taxon rank (” otherwise), `decade` NA outside the decade
layers, `year` NA outside the year layers.

## Examples

``` r
if (FALSE) { # \dontrun{
con <- obis_store_connect("~/data/obis/obis_h3.duckdb")
obis_h3_export_parquet(con, "~/data/obis-h3", "v20260728")
} # }
```
