# obisindicators 0.12.0

* **`species_flat` per resolution.** `obis_h3_export_parquet()` writes
  `species_flat/res=1.parquet` and `res=2.parquet` beside `res=3.parquet`
  (`res_species_flat` now defaults to `1:3`): the finest resolution comes from
  the store as before (with `h3`), each coarser one is it rolled up, one row
  per cell and species with `n` summed, `year_min` the least and `year_max`
  the greatest (NULL only when every year is NULL), so a res-1 hexagon reads
  its own rows instead of its res-3 children's. The roll-up files have the
  columns `cell_id, name_key, aphiaid, n, year_min, year_max` (no `h3`).
  New exported `obis_h3_species_rollup_sql()` (the roll-up, equal to
  `obis_h3_species_sql()` at that resolution straight from the store) and
  `obis_h3_write_species_flat()`.
* **The res-3 species table split by res-1 parent**:
  `species_flat/res=3/p=<res-1 parent>.parquet`, one file per parent with
  records, without the `h3` column, sorted by `cell_id, aphiaid` in row groups
  of `split_row_group_rows` (default 2048) with `cell_id` statistics, so a
  cell's file is small enough for its footer to come with the first range
  read. The files union to `res=3.parquet`, which is kept. New arguments
  `species_flat_split` (default `c("3" = 1L)`, resolution = parent resolution;
  NULL for none) and `split_row_group_rows`. `release.json`
  `layers.species_flat` gains `template_parent`, `parent_template`,
  `parent_res`, `by_res` and `split`; `files.parquet` gives each split file's
  `parent`.
* **The species lookup carries each species' EOV** and **its lineage has a
  file of its own.** `species/species.parquet` gains `eov`: the EOV whose layer
  counts the aphiaid, the store's `eov` table joined on `taxonID = aphiaid` as
  the `eov/` layers join `occ_h3` (`obis_h3_species_eov_sql()`); NULL when no
  EOV counts it, and the column is left out when the store has no `eov` table.
  The seeds are disjoint subtrees of one tree, so an aphiaid is in one EOV at
  most; an aphiaid in two is an error, not a choice. `species/lineage.parquet`
  holds `aphiaid, name_key, lineage` only, sorted by aphiaid, so a WoRMS subtree
  reads the lineage without the names. Both are written in row groups of
  `row_group_rows` (`obis_h3_write_species_lookup()`). No `redlist_code` column:
  the store's `occ_h3` and `taxon` tables carry no IUCN Red List field (the OBIS
  snapshot's `interpreted.redlist_category` is not brought into the store).
* **`obis_h3_amend_species()`** adds these files to a release built by 0.11 in
  place: the lookup rewritten with `eov` (same rows, same order), the lineage
  file, the roll-ups and the split from the existing `res=3.parquet` (not
  rewritten), `release.json` and `files.parquet` (the new files added, every
  other row kept). Used to amend v20261012.
* **The collection describes them.** `obis_h3_stac_collection()` lists
  `obis:species.flat` at every flat resolution with the split's
  `parent_template` (`species_flat/res={res}/p={parent}.parquet`), `parent_res`
  and the columns of each file, `obis:species.lineage`, `obis:species.eov`,
  and the assets `species_flat_res<r>` and `species_lineage`;
  `obis_h3_stac_stable()` makes those hrefs absolute. The h3 profile 1.1 closes
  `h3:species_table` (no keys beyond its seven), so the flat files stay
  described under `obis:species.flat`, where the atlas reads them;
  `h3:species_table` is unchanged.

# obisindicators 0.11.0

* **Every indicator layer file is sorted by `cell_id` in small row groups.**
  `obis_h3_export_parquet()` gains `row_group_rows` (default 10000; DuckDB
  row groups are at most 2 x `row_group_rows`; DuckDB rounds to 2,048-row
  vectors: 12,045 rows at most in v20261012) and writes each file of the
  `all`, `eov`, `taxon`, decade and year layers with its own sorted `COPY`
  (`obis_h3_write_partitions()`, `order_by = "cell_id"`), so the `cell_id`
  statistics of consecutive row groups are disjoint and a reader that knows
  the cells under a tile range-reads only those groups. DuckDB's
  `PARTITION_BY` wrote the groups out of order (the v20261012 `all/res=5`
  file had 6 groups of up to 122,880 rows, not in `cell_id` order). The paths
  are unchanged (the explicit writer encodes partition values as DuckDB did:
  all 7,370 v20261012 taxon paths compare equal). `release.json` records
  `sorted_by`, `row_group_rows` and `row_group_rows_max` (the largest group
  written). `max_open` is no longer used. `stats.parquet` is written in row
  groups of `row_group_rows` too (sorted by `layer, key`, so a legend reads only
  its layer's groups; the v20261012 file's first 122,880-row group held `all`,
  `eov` and half the taxa).
* **The heads are built, as taxon layers.** `obis_h3_export_parquet()` writes
  the taxa of `species/heads.json` (Animalia and every taxon spanning two or
  more named classes) under the existing `taxon/rank=<rank>/taxon=<name>/res=<r>/`
  layout at `res_heads` (default 1-7, res 6 and 7 split by `parent_res_taxon`),
  so a reader draws a head as any taxon layer and never reads the class files;
  they are in `stats.parquet`, `taxon_groups.parquet` and `files.parquet` like
  the rank layers. `rank` is the WoRMS rank lowercased without a botanical
  alias (`kingdom`, `subphylum`, `superclass`; "Phylum (Division)" is
  `phylum`). New exported `obis_h3_heads_sql()`: the WoRMS subtree over the
  lookup's `lineage`, species counted by `name_key`, so a head equals
  `obis_h3_species_subtree_sql()` cell for cell (tested at res 3-5, and against
  h3t's recursive-CTE subtree at res 1-7). A head is not written when a layer
  already serves it: a subtree holding every aphiaid is the `all` layer (Biota:
  equal to `all` cell for cell at res 4 on v20261012), and a head whose rank and
  name are a rank layer keeps that layer, which is built from the OBIS rank
  column (the 40 phyla among the v20261012 heads; Chordata's phylum layer
  differs from its WoRMS subtree in 1,967 of 173,824 res-4 cells). `heads.json`
  gives each head's `served_by` (`head`, `all`, `rank_layer`, `homonym`) and
  `layer`; `release.json` gets `layers.taxon.heads` and
  `layers.species.heads.n_built`. New arguments `heads` (default TRUE) and
  `res_heads`.
* **The species table carries the first and last year.** `obis_h3_species_sql()`
  and every species file gain `year_min` and `year_max` (SMALLINT; the first and
  last year the aphiaid was recorded in the cell, NULL when no record has a
  year; within the decade in the decade variant), for the Cell pane.
* **The decade species table is on by default**, at res 3 and 4:
  `species_decades` now defaults to TRUE and the new `res_species_decade`
  (default `c(3, 4)`) sets its resolutions (it followed `res_species` before),
  for the decade filter on a WoRMS subtree. `layers.species_decade` in
  `release.json` lists its `resolutions`, `decades` and `columns` (with
  `period = "decade"`).
* **`species_flat/res=<r>.parquet`**: the species table in one file per
  resolution for every class, sorted by `cell_id, aphiaid` in row groups of
  `row_group_rows`, so the species of a cell are a range read of one file
  (spike 2: 0.53 MB read for a res-1 cell against 5.3 MB from the class files).
  New argument `res_species_flat` (default 3); `release.json` gets
  `layers.species_flat`.
* **Exact species per place.** `obis_place_indicators_exact()` returns
  `species` (new argument `species = TRUE`): one row per place x `aphiaid` x
  `name_key` with `n` records and `year_min`, `year_max`, from the same
  point-in-polygon pass as the indicators, so the Place page's species list is
  the record and not the H3 cells' (the species' `n` sum to the place's `n`, and
  its distinct `name_key` count is its `sp`). New argument `lookup` (the
  release's `species/species.parquet`, a path or a data frame) gives the
  release's `name_key` by name, so the rows join the lookup; a name it lacks
  gets a key above its largest. `obis_place_exact_write()` writes
  `place_exact/coll=<coll>/species.parquet` (`place_id, aphiaid, name_key, n,
  year_min, year_max`, most records first) and counts it in `meta.json`;
  `obis_h3_add_place_exact()` lists it in `files.parquet` and adds its template
  and columns to a `release.json` entry written before 0.11.0. The export passes
  the store's lookup; `data-raw/run_place_exact.R` reads
  `<out dir>/species/species.parquet` (or `OBIS_SPECIES_LOOKUP`) and fails when
  the species do not sum to the indicators.
* **`collection.json` for the `h3` profile 1.1, with the atlas hooks.**
  `obis_h3_stac_collection()` now writes the collection with id `obis_h3` (was
  `obis-h3`; the atlas names it `?c=obis_h3`) for profile
  `https://oceanmetrics.io/schemas/h3/v1.1.0/schema.json`: `h3:periods` as two
  period sets (decades at `res_decade`, years at `res_year`, each with its
  template), `h3:layout.row_group_rows`, `h3:species_table.columns` with
  `name_key`, `year_min`, `year_max` and the decade variant's `period`,
  `h3:heads` (`{layer: "taxon"}`), `cube:dimensions` (`layer`: all and the EOVs;
  `indicator`; `period`: all, decades as `<yyy0>s`, years; `res`),
  `atlas:metric` (`es`), `item_assets`, and one STAC Item per map layer
  (`items/<all|eov>.json`, with `data`, `decade` and `year` assets: a folder and
  the path template under it). `stats.parquet` is the asset with role `legend`,
  `taxon_groups.parquet` the one with role `search`. New argument `items`.
* **New `obis_h3_stac_stable(release_dir, base_url)`** writes the copy for a
  stable url, `obis-h3/collection.json`, with every href and template absolute
  under the release folder; `data-raw/refresh_obis_h3.sh` writes it after
  `latest.json` (step g2), validated with `om-catalog validate h3` (exit 5 when
  it fails). Both validate against the 1.1 schema (jsonvalidate and the node
  CLI), with counter-fixtures (a period set without `placeholder`, `year_min`
  without `year_max`) failing.
* Fix: `taxon_groups.parquet` no longer fails for a taxon layer without res 1.

# obisindicators 0.10.1

* **New `obis_h3_add_place_exact(release_dir, coll, source, manifest)`**: registers
  a `place_exact/coll=<coll>/` collection written into a release that was built
  without it (or without that collection), for example the gazetteer `places`
  (the 18 national marine sanctuaries) computed with `data-raw/run_place_exact.R`
  on a staging copy of the published release. `release.json` gets the
  collection under `layers$place_exact$collections` (from its `meta.json`) and
  the layer's `rows`, `files` and `bytes` over every collection on disk;
  `files.parquet` has its `place_exact` rows replaced by one row per file on disk
  and `files$n_files` is updated (`manifest = FALSE` leaves it alone). Other
  layers, `stats.parquet` and a hand-edited layer `note` are untouched, and a
  second call gives the same files.
* The exact place layer's `template`, `columns` and `note` in `release.json` come
  from one internal helper shared by the export and the new function.

# obisindicators 0.10.0

* **Year layers.** `obis_h3_export_parquet()` writes
  `year/all/year=<yyyy>/res=<r>/data_0.parquet` and
  `year/eov/eov=<eov>/year=<yyyy>/res=<r>/data_0.parquet`: the decade layers
  per year, one partition per year present from `min(date_year)` to
  `max(date_year)`. New arguments `res_year` (default 1-5; `integer(0)` skips
  them) and `years` (default NULL, every year). The SQL is the new exported
  `obis_h3_year_sql()`, built on the same indicator SQL as `idx_h3` and the
  decade layers (which now share its builder). `release.json` gains
  `layers.year_all`, `layers.year_eov`, `res_year`, `years` (the years
  written), `year_range` and `year_note`; `files.parquet` and `stats.parquet`
  cover them.
* **`stats.parquet` has a `year` column** (NA outside the year layers), so its
  rows are one per layer x key x decade x year x res x variable.
* **The species x hex x count table** (layer `species`, sized and checked
  against h3t in spike 2 of the Ocean Metrics restructure), so a browser
  answers a WoRMS subtree or a cell's species list from static files:
  `species/res=<r>/class=<class>/data_0.parquet` with columns
  `h3, cell_id, name_key, aphiaid, n` (`n` = records) at the resolutions
  `res_species` (default 3, 4, 5; res 4 rolled up from the res-5 tier), one
  file per (res, class), sorted by `cell_id, aphiaid` in row groups of 100k
  (ZSTD); a NULL class is written `class=_none`, since DuckDB-WASM reads
  `__HIVE_DEFAULT_PARTITION__` as a string. `species/species.parquet` is the
  lookup, one row per aphiaid with `name_key` (a dense integer per species
  name: richness counts names, as h3t does), the OBIS ranks, `lineage`
  (the aphiaid then its ancestors up the store's `taxon` table, walked from the
  occurrence's own aphiaid, so a synonym keeps its own parent) and `records`.
  `species/heads.json` lists the taxa that still need a pre-aggregated head
  (Animalia and every taxon spanning two or more named classes: 125 in the
  v20261012 global store); the heads themselves are not built in this
  version. `species_decades = TRUE` also writes
  `species_decade/res=<r>/decade=<d>/class=<class>/data_0.parquet` (default
  off). A store without aphiaids (the demo store built from `occ_SAtlantic`)
  gets no species layer.
* New exported functions for the table, each tested on a synthetic store:
  `obis_h3_species_sql()`, `obis_h3_species_lookup_sql()`,
  `obis_h3_species_heads()`, `obis_h3_write_partitions()` (the explicit
  per-partition writer: DuckDB's `PARTITION_BY` wrote thousands of files per
  resolution and lost the sort) and `obis_h3_species_subtree_sql()` (a
  subtree's indicators from the exported files, which reproduce the h3t
  subtree SQL cell for cell: `n` and `sp` exactly, Shannon, Simpson and ES to
  1e-9).
* **`collection.json`**: the export writes a STAC Collection of the release
  for the Ocean Metrics `h3` profile, `obis_h3_stac_collection()`, with
  `h3:species_table` for the species layer and the other layers under
  `obis:layers`. It validates against `h3.schema.json` (tested with
  jsonvalidate and with `om-catalog validate h3` when the platform checkout is
  present).
* `release.json`'s `layers.species` carries the `h3:species_table` fields
  (`href_template`, `resolutions`, `partition_by`, `sorted_by`, `columns`,
  `lookup`) plus `name_key`, `null_class`, `heads`, the column types and the
  rows, files and bytes per resolution (`by_res`).
* The `place` and `place_exact` layers of 0.8.0 and 0.9.0 are unchanged: they
  stay out of `stats.parquet`, and `collection.json` lists them under
  `obis:layers`.

# obisindicators 0.9.0

* **New `obis_place_indicators_exact()`: indicators per place from the OBIS
  occurrences inside the true polygon, with no H3 approximation.** It takes the
  occurrences (a data frame, or OBIS open-data parquet files, nested or flat,
  filtered as `build_obis_h3_duckdb()` does) and the places (an `sf` object or a
  GeoParquet with `place_id` and WKB `geometry`, such as a gazetteer
  `places.parquet`), splits each polygon into its parts and cuts them into quadrants until every piece has
  at most `max_vertices` (default 256) vertices (a place split at +/-180 gets local
  parts, so memory stays a few times the geometry size), joins every distinct
  location to the pieces with DuckDB spatial, and computes the indicators with the
  same SQL as the store's layers. Polygons split at +/-180 work as they are.
  Returns `indicators` (place x `eov` x `decade`; `eov` is `"all"` or an EOV from
  the `eov` membership given as a data frame or a store connection; `decade` NA =
  all years), `years` (place x `eov` x `year`) and `diagnostics`. Columns: `n`,
  `sp`, `shannon`, `simpson`, `es`, `hill_1` (`exp(shannon)`), `hill_2`
  (`1 / simpson`), `bp` (Berger-Parker, `max(ni) / n`) and `density` (`n /
  area_km2`, records per km2, from `area_km2` or the geodesic polygon area).
  `diagnostics` holds `records_in`, `records_out` and `records_total` (inside
  plus outside equals the total unless places overlap), `records_in_unique` and
  the overlapping locations with their `place_id`s, which also raise a warning.
  Resource guards (`memory_limit`, `threads`, `temp_dir`, `max_temp_dir_size`) as
  in `build_obis_h3_duckdb()`. The results equal `calc_indicators()` on the points
  inside the polygon (tested for all taxa, per decade, per year and for each of the
  seven EOVs).
* New `obis_place_exact_write()` writes that result as
  `place_exact/coll=<coll>/indicators.parquet` and `years.parquet` (ZSTD, values
  only, no geometry) plus a `meta.json` (places, rows, record totals, overlaps,
  package version).
* `obis_h3_export_parquet()` gains `place_exact` (a named list of slug = places
  GeoParquet; default `NULL`, no change), `place_exact_occ` (the occurrence
  parquet files), `temp_dir` and `max_temp_dir_size`: the exact place tables are
  written to `place_exact/coll=<slug>/` in the release and listed in
  `files.parquet` (layer `place_exact`) and `release.json`
  (`layers$place_exact`); `stats.parquet` does not cover them. The monthly
  refresh turns it on with `OBIS_PLACE_EXACT_COLLECTIONS="<slug> ..."`, reading
  `$PLACES_INTERNAL/<slug>/places.parquet` (default `/share/data/places-internal`),
  passed through, and mounted read-only, by `run_refresh_docker.sh`.
  `data-raw/run_place_exact.R` runs the same computation standalone.
* `obis_place_indicators_exact()` takes `max_vertices` instead of `grid_deg`
  (deprecated: ignored, with a message). The 1 degree grid clip repeated each
  place's whole geometry in every cell of its bounding box, which ran out of memory
  on EEZs and high seas that span +/-180; the quadrant subdivision writes one table
  per round and copies a geometry at most four times. `diagnostics` reports
  `max_vertices`, `max_piece_vertices` and `subdivision_rounds` instead of
  `grid_deg`; `data-raw/run_place_exact.R` reads `OBIS_MAX_VERTICES`.
* No change to the indicator math or to the output of any existing function.

# obisindicators 0.8.0

* **New `obis_place_indicators()`: indicators per place, pooled from
  area-weighted H3 cells.** It takes a place-cell membership (`place_id`, `h3`,
  `share`, as the Ocean Metrics gazetteer publishes it per collection) and, for
  each place, sums every species' records over the member cells weighted by the
  cell's share of area inside the place (`ni = sum(records * share)`; the
  gazetteer keeps shares of at least 1%), then computes `n`, `sp`, Shannon,
  Simpson and ES(50) with the store's indicator SQL. Layers `all` and `eov` (per
  EOV), each for all years and per decade (1960-2020, as the export's decade
  layers); also `cells` (member cells with records) and `area` (their summed
  share). These are true per-place indices of the pooled, area-weighted counts,
  not means of hexagon values: `n` is fractional because of the weighting,
  richness counts every species with any weighted record inside the place, and
  ES(50) is NA where the weighted `n` is below 50.
* New `obis_place_membership()` resolves a gazetteer collection (slug,
  directory, URL or `membership.json`) to its membership parquet files at one
  resolution.
* `obis_h3_export_parquet()` gains `place_collections` (default `NULL`, no
  change): a named list of collections, each written as one file
  `place/coll=<slug>/data_0.parquet` with every place, layer and decade, listed
  in `files.parquet` (layer `place`) and `release.json` (`layers$place`, with
  each collection's membership version). `stats.parquet` does not cover it.
  The monthly refresh turns it on with `OBIS_PLACE_COLLECTIONS="<slug> ..."`
  (optionally `GAZETTEER_BASE`), passed through by `run_refresh_docker.sh`.
* The shared indicator SQL (`.h3t_indicators_sql()`) is documented for
  fractional counts; it needed no change, and integer results are unchanged.

# obisindicators 0.7.3

* **`release.json`'s `obis_snapshot` is the OBIS data date**, the date of the
  newest object in `s3://obis-open-data/occurrence/` the store was built from,
  not the date the refresh ran. OBIS updates that folder one dataset at a time
  and publishes no export date, so `refresh_obis_h3.sh` reads it off the synced
  files (which `aws s3 sync` stamps with their S3 `LastModified`) and passes it
  as `OBIS_DATA_DATE`; without it, the date in the release tag is used as
  before. For v20261012 that is 2026-10-11 (synced 2026-10-12). The release tag
  stays the sync date.
* `latest.json` also carries `worms_version`, the ChecklistBank WoRMS version
  the taxonomy came from.

# obisindicators 0.7.2

* **Family is a precomputed taxon rank.** `H3T_IDX_RANKS` gains `"family"`, so
  the store's `idx_h3_taxon` and the export's `taxon/rank=family/` layer carry
  every family (about 5,800 in the v20260728 store), and a single-family h3t
  query takes the precomputed path. `migrate_add_idx_h3_taxon.R` adds it to an
  existing store.
* **The monthly `obis-h3` refresh runs in Docker on the Mac mini.** New
  `data-raw/docker/Dockerfile` (R 4.6.1, CRAN from a dated Posit Package
  Manager snapshot, duckdb 1.5.5, the h3/spatial/httpfs extensions, AWS CLI v2)
  and `data-raw/run_refresh_docker.sh` (Colima VM started and stopped per run,
  data on the external drive mounted at `/share/data`, the new store rsynced to
  msens for h3t). `refresh_obis_h3.sh` runs R directly when `BUILD_CONTAINER`
  is empty (inside the image); msens's `docker exec plumber` mode is unchanged.
* `refresh_obis_h3.sh` sources every file in `R/` for the export: the subset it
  sourced before lacked `eov.R`, so the export stopped at `taxon_groups`
  (`could not find function "obis_eov_label"`).
* `obis_h3_export_parquet()` computes `stats.parquet` one layer and variable at a
  time: the single UNPIVOT over every layer held all values in `quantile_cont()`
  states at once and, with the family rank, was killed for lack of memory in a
  24 GiB VM. Same rows, values and column types (regression test).
* **The WoRMS taxonomy is refreshed by the monthly run.** New step (a2) in
  `refresh_obis_h3.sh`: when the `version` of ChecklistBank dataset 2011 (WoRMS's
  monthly DwC-A, public) differs from `taxon.parquet.json`, it downloads the
  archive, runs `build_taxon_parquet.R` and records the version, which
  `release.json` carries as `worms_version`. New flags `--skip-taxonomy` and
  `--taxonomy-only`. The build's gap-fill of AphiaIDs missing from the download
  (WoRMS REST) is unchanged. `run_refresh_docker.sh` skips a separate mount for a
  checkout that sits inside the data folder (Colima refuses overlapping mounts).
* `release.json`'s `obisindicators_version` comes from the checkout's
  `DESCRIPTION` when `OBIS_PKG_ROOT` is set (`.obisindicators_version()`), so
  the image needs no installed package.

# obisindicators 0.7.1

* **`obis_h3_export_parquet()` splits the fine resolutions by parent cell**, so
  a browser loads only the cells covering its viewport instead of a whole
  33 MB `all/res=7` file. New arguments `parent_res` (default
  `c("6" = 2L, "7" = 3L)`: res 6 by its res-2 parent, res 7 by its res-3
  parent, for the `all` and `eov` layers), `parent_res_taxon` (default the
  res-0 base cell, which keeps the taxon layer to thousands rather than
  millions of files), `parent_min_rows` (default 50000: smaller
  (layer key, res) partitions stay whole) and `max_open` (partitions per
  COPY). Split partitions are written to `.../res=<r>/p=<parent h3>/data_0.parquet`;
  res 1-5 and the decade layers stay whole. `files.parquet` gains a `parent`
  column (NULL for whole files) and `release.json` documents each layer's
  `parent_res` and the rule (`parents`).
* **New `data-raw/refresh_obis_h3.sh`: the monthly `obis-h3` release pipeline** (sync OBIS open data, build
  the store, `obis_h3_export_parquet()`, validate against the previous release, upload to S3, then write
  `obis-h3/latest.json`). Scheduled from `oceanmetrics/erddap-places` on the msens runner; documented in
  `data-raw/README.md`. Supports `--skip-sync/-build/-export/-upload`, `--release` and `--dry-run`.

# obisindicators 0.7.0

* **New `obis_h3_export_parquet()`: export a store to hive-partitioned Parquet
  for a serverless web app** (static hosting + DuckDB-WASM + deck.gl
  `H3HexagonLayer`). Writes `<dir_out>/<release>/` with `all/res=N/`
  (`idx_h3`), `eov/eov=<eov>/res=N/` (`idx_h3_eov`),
  `taxon/rank=<rank>/taxon=<taxon>/res=N/` (`idx_h3_taxon`), and two layers
  computed from `occ_h3` per decade (`decade/all/decade=<yyy0>/res=N/`,
  `decade/eov/eov=<eov>/decade=<yyy0>/res=N/`; res 1-5 and decades 1960-2020
  by default). Every file has `h3` (lowercase hex string), `cell_id`, `n`,
  `sp`, `shannon`, `simpson`, `es`. Also writes `stats.parquet` (min, 2nd,
  50th, 98th percentile, max and cell count per layer x key x res x variable,
  for colour ramps), `taxon_groups.parquet` (the taxa and EOVs on offer, with
  totals and on-disk / URL paths), `files.parquet` (a manifest of every file
  with its row count and size, since HTTP cannot glob) and `release.json`
  (release, snapshot, package and DuckDB versions, row counts per layer,
  layout and columns). Each partition is exactly one `data_0.parquet`; the
  taxon layer is written in batches of at most 100 partitions per COPY to stay
  under the OS open-file limit.
  Partition values are percent-encoded by DuckDB; `url_path` gives the form to
  fetch over HTTP.
* The indicator SQL behind `idx_h3`, `idx_h3_taxon` and `idx_h3_eov` now comes
  from one internal builder (`.h3t_indicators_sql()`), which the decade layers
  of the export reuse. The output of the store build is unchanged.
* `jsonlite` added to Suggests (used by the export).

# obisindicators 0.6.1

* **Precomputed store articles: the figures now show on the pkgdown site (and
  in the `paper/` gallery on GitHub).** The vignettes that query an `obis_h3` store (`scaling`,
  `taxon_children`) rendered code-only (`eval = FALSE`) because the store is not
  available on GitHub Actions. They move to `vignettes/articles/` (pkgdown-only,
  excluded from the package build) as `*.Rmd.orig` sources that
  `data-raw/precompute_articles.R` knits locally against a store into committed
  `*.Rmd` + `figures/`; CI renders those as-is. The tile maps stay live.
  - The `paper/` Quarto notebooks are folded into the articles, which now double
    as the manuscript's figure notebooks: `scaling` (Tables 2, 5; Fig. 3),
    `taxon_children` (Table 3; Fig. 4), and new articles `eov` (Table 4;
    Figs. 1–2), `decadal` (Fig. 5) and `places` (Fig. 6). Each article saves
    its manuscript figure + CSV to `paper/figures/` (now committed) via
    `paper/_common.R`; `paper/README.md` is the figure gallery and index.
  - Site navigation: articles are grouped into "Shipped data" and "The obis_h3
    store". No changes to exported functions.

* **Analysis-side helpers for the paper's figures and case studies** — the
  tile-SQL builders now have data-frame counterparts, so every figure in
  `paper/` is a call to a tested, exported function rather than notebook code.
  No new indicator math: everything runs the SQL already pinned to
  `calc_indicators()` / `calc_spue()`, or calls those references directly.
  - Store (`R/store.R`): `obis_store_connect()` (read-only + `LOAD h3`),
    `obis_store_stats()` (tables, totals, cells by resolution — Table 2),
    `obis_h3t_query()` (run any tile SQL at a fixed resolution, keyed on the
    hex string), `obis_cell_indicators()` (n/sp/shannon/es per cell for any
    filter, reading `idx_h3` / `idx_h3_eov` when it can), `obis_bench()` +
    `obis_bench_queries()` (cold/warm timings of the four serving paths),
    `h3_res_table()`.
  - Scale (`R/scale.R`): `calc_scale_curves()` and `calc_spue_scale()` —
    occupied cells, records-per-cell quantiles, ES-eligible fraction, medians
    and reliability floors across H3 resolutions (Fig. 3).
  - Comparisons (`R/compare.R`): `calc_rank_vs_subtree()` +
    `obis_rank_presets()` (records by DwC rank column vs AphiaID subtree —
    Table 3), `calc_eov_totals()` + `compare_eov_totals()` (per-EOV totals and
    before/after a taxonomy change — Table 4), `calc_spue_cells()`,
    `h3_raster_to_cells()` (aggregate an SDM raster to H3 by pixel centres or
    hexagon centroids) and `compare_spue_sdm()` (Spearman + calibration bins,
    effort-gated — Fig. 4).
  - Periods (`R/temporal.R`): `calc_period_indicators()` and
    `calc_period_change()` (decadal ES50/richness per cell, change where both
    decades are reliable — Fig. 5).
  - Places (`R/place.R`): `place_cells()` and `calc_place_indicators()` (roll
    H3 cells up to sanctuary/EEZ polygons and compute indicators with
    `calc_indicators()` — Fig. 6).
  - Visualize (`R/visualize.R`): `hex_sf()` (cells → dateline-wrapped
    polygons), `gmap_cells()` (map a per-cell table with an optional
    reliability mask), `plot_scale_curves()`, `plot_spue_sdm()`;
    `gmap_indicator()` gains a `bbox` argument and drops the deprecated
    `aes_string()`.
  - Tests: `tests/testthat/test-paper-helpers.R` on a new synthetic fixture
    (`helper-paper.R`: turtles + birds with DwC ranks and years, baked
    `idx_h3` and `idx_h3_eov`) asserts exact values for every helper, including
    precomputed-vs-live agreement of `obis_cell_indicators()`.
  - `paper/`: Quarto notebooks, one per figure/table (store stats + benchmarks,
    rank vs subtree, gap-fill EOV totals, EOV maps, scale curves, SPUE vs SDM,
    decadal change, place roll-ups), driven by `OBIS_H3_DUCKDB`; plus
    `paper/build_demo_store.R` to build a regional demo store (Gulf of
    Mexico + Caribbean) from a local OBIS export and a WoRMS table.
  - Suggests: `terra` (raster aggregation), `patchwork` (figure panels).

# obisindicators 0.5.0

* **Essential Ocean Variables (EOVs)** — new `R/eov.R` maps the GOOS/IOOS
  biology & ecosystems EOVs onto the H3 store. The
  [IOOS Marine Life Data Network](https://github.com/ioos/marine_life_data_network/tree/main/eov_taxonomy)
  defines each EOV as a handful of root WoRMS AphiaIDs (33 seeds across 7 EOVs:
  fish, hardCorals, mangroves, marineMammals, seabirds, seagrasses, seaTurtles),
  which is exactly a multi-seed version of the existing subtree walk.
  - `obis_eov_seeds()` / `obis_eov_aphiaid()` — the EOV definitions.
  - `obis_eov_sql()` — tile SQL for an EOV, routing to a precomputed layer when
    it can and to the live AphiaID-subtree path when it must (year filters,
    several EOVs at once, or a store without the layer baked).
  - `obis_eov_bake()` — adds `eov` (membership) and `idx_h3_eov` (precomputed
    indicators, res 1-7) to a store; now also a step in
    `build_obis_h3_duckdb()`, skipped with a note when `taxon` is absent.
  - New driver `data-raw/migrate_add_eov.R`.

* **WoRMS gap-fill** — new `R/taxon_gapfill.R` closes a silent coverage hole.
  The bulk WoRMS `taxon.txt` download is not a complete cover of the AphiaIDs
  OBIS carries: on the 2026-07 global store 12,021 of 167,190 distinct
  `occ_h3.aphiaid` values (~7%, covering 8.3M of 121.9M records) were absent
  from `taxon`, so they were invisible to every `aphiaid` / EOV / SPUE query.
  - `obis_taxon_orphans()` — report the gap.
  - `wm_aphia_records()` — batched, parallel WoRMS REST lookups
    (`AphiaRecordsByAphiaIDs`, 50 ids/request), the per-id supplement to the
    bulk download.
  - `obis_taxon_fill_gaps()` — fills orphans **and** iterates to transitive
    closure, because inserting an orphan whose ancestors are still missing
    leaves it disconnected from any seed above it. Warns and reports
    `closed = FALSE` rather than implying a whole tree if `max_rounds` is hit.
  - New driver `data-raw/migrate_fill_taxon_gaps.R`.
  - Adds `httr2` to Suggests.

* **Two taxon-group presets in the h3-db app returned zero records** (fixed in
  `MarineSensitivity/apps/h3-db`, noted here because it motivated the EOV
  design): filtering the DwC `class` column cannot match when WoRMS files the
  name at another rank — `class='Actinopterygii'` (a Gigaclass; OBIS's class is
  `Teleostei`, 44.2M records) and `class='Anthozoa'` (a Subphylum; OBIS uses
  `Hexacorallia`/`Octocorallia`) both matched nothing. AphiaID subtree walking
  is rank-agnostic and immune to this.

* Parity: `.h3t_idx_eov_sql()` is a fifth copy of the `calc_indicators()` ES(n)
  term and is pinned cell-for-cell by the new `tests/testthat/test-eov-parity.R`.

# obisindicators 0.4.2

* **Vignette H3 tile maps now actually render** (the `mapgl`/MapLibre chunks that
  0.4.1 still left as code-only):
  - `vignette("h3t")` renders the interactive ES50 hexagon map; `vignette("taxon_children")`
    renders the Cetacea-records map and the SPUE map. These are client-side
    MapLibre widgets — tiles are fetched from the deployed `h3t` service in the
    reader's browser, so they need no store/S3 at build time.
  - **New Remote dependency**: the maps require the h3t-antimeridian fix in
    `mapgl` (renders H3 hexagons that cross the dateline), pinned via
    `Remotes: mapgl=bbest/mapgl@fix/h3t-antimeridian`
    ([walkerke/mapgl#211](https://github.com/walkerke/mapgl/pull/211)). Switch to
    upstream `mapgl` once that PR merges.
  - Fixed a latent bug in the `h3t` map example — `interpolate(values=)` now has
    the same length as `stops=` (a 3-stop viridis ramp), which previously would
    have errored had the chunk been evaluated.
  - `vignette("scaling")` stays code-only: every chunk runs live benchmark
    queries against the deployed DuckDB store (no map widgets), which CI cannot
    reach.

# obisindicators 0.4.1

* **Vignettes now render their evaluable R chunks** on the pkgdown site instead
  of showing code-only:
  - `vignette("h3")` runs the full h3-grid → `calc_indicators()` → `gmap_indicator()`
    pipeline on shipped `occ_1M` and renders the ES(50) map (only the `deckgl`
    install/demo stays code-only).
  - `vignette("taxon_children")` now renders the generated `WITH RECURSIVE`
    tile SQL and tile URLs from `obis_h3t_sql(aphiaid=)` / `obis_spue_sql()`
    (pure builders, no store needed); only the DB-connection and `mapgl`
    widget chunks stay code-only.
  - `vignette("h3t")` suppresses package-load messages so the evaluated
    `obis_h3t_sql()` output is clean.
  - Chunks that genuinely require the deployed S3 / DuckDB store / `h3t` tile
    service (`vignette("scaling")`, the build/deploy/map chunks) remain
    illustrative code, as they cannot run in CI.

# obisindicators 0.4.0

* **Automatic per-tile spatial pruning via `hex_prune`** (supersedes 0.3.0's
  client-side `{{bbox}}` placeholder). The tile bbox is fully determined by the
  `z/x/y` tile address, so the client no longer states it — the `h3t` server
  derives each tile's covering coarse H3 cells from `z/x/y` and injects the
  prune itself:
  - `build_obis_h3_duckdb()` now materializes a coarse H3-parent column
    `hex_prune = h3_cell_to_parent(cell_id, LEAST(res, H3T_PRUNE_RES))` (res 3)
    on `occ_h3` and `idx_h3` and clusters both by `(res, hex_prune, cell_id)`.
    This replaces the interim `lat`/`lng` clustering — pruning on the H3 index is
    2D (tighter than a latitude band), needs no extra float columns, and the
    covering ids are canonical H3 (they match across the R build and the server
    with no version drift). **Store schema change** — rebuild, or migrate with
    `data-raw/migrate_add_spatial_cluster.R` (drops `lat`/`lng`, adds `hex_prune`).
  - `obis_h3t_sql()` / `obis_spue_sql()` now emit **plain per-resolution
    SELECTs** — the `bbox_placeholder` argument is **removed**. The server
    (`MarineSensitivity/server/h3t`, `CalCOFI/api-h3t-py`) rewrites the query to
    add `hex_prune IN (<covering cells>)` to any scan of a table carrying that
    column; stores without it are untouched.
  - The math is unchanged and still pinned to `calc_indicators()` /
    `calc_spue()`; `test-h3t-prune.R` asserts the prune is **result-preserving**
    (a `hex_prune`-pruned scan + the server's outer centroid filter returns
    exactly the same cells and values as the unpruned scan).

# obisindicators 0.3.0

* **Spatial (bbox) tile pruning** *(interim — the `{{bbox}}` placeholder and
  `lat`/`lng` clustering here were replaced by the `hex_prune` approach in
  0.4.0; kept for history)*. Live `occ_h3` / `idx_h3` tile maps were pruned per
  tile instead of aggregating the whole globe for every tile:
  - `build_obis_h3_duckdb()` materialized cell-centroid `lat`/`lng` columns on
    `occ_h3` and `idx_h3` and clustered both by `(res, lat, lng)`.
  - `obis_h3t_sql()` / `obis_spue_sql()` gained a `bbox_placeholder` argument
    (default `"{{bbox}}"`) that the `h3t` service substituted per tile with a
    `lat`/`lng` predicate.
  - The math stayed pinned to `calc_indicators()` / `calc_spue()`; the prune was
    asserted result-preserving.

# obisindicators 0.2.0

* Added **WoRMS taxonomy children resolution** and an **effort proxy (SPUE)** so
  OBIS can be filtered by any WoRMS AphiaID at any rank from the local snapshot
  (see `vignette("taxon_children")`, `vignette("scaling")`):
  - `obis_taxon_children()` / `obis_taxon_subtree_sql()` recursively walk a
    `taxon` table (baked into the store; `data-raw/build_taxon_parquet.R` +
    `data-raw/migrate_add_taxon.R`) to return every descendant taxon.
  - `obis_h3t_sql(aphiaid=)` serves arbitrary-rank children maps by filtering
    `occ_h3.aphiaid` to the resolved subtree via a `WITH RECURSIVE` CTE.
  - `calc_spue()` (R reference) + `obis_spue_sql()` compute the presence-only
    effort proxy `records(target subtree) / records(effort subtree)` per cell,
    pinned by `test-spue-parity.R`.

* Added an **H3 tiling (h3t)** workflow to serve indicators as on-demand H3
  hexagon map tiles (see `vignette("h3t")`):
  - `build_obis_h3_duckdb()` builds an authoritative DuckDB store from OBIS
    open-data parquet — a precomputed all-taxa indicator layer (`idx_h3`, res
    1–7) plus a species-level store (`occ_h3`, tiers 3/5/7) for on-the-fly
    taxon/year-filtered queries. The ES50/Shannon/Simpson/richness math is the
    SQL translation of `calc_indicators()`, pinned by a new parity test.
  - `obis_h3t_sql()` / `obis_h3t_url()` compose the validated read-only `SELECT`
    and the base64-encoded tile URL for the `h3t` service
    (`MarineSensitivity/server/h3t`) and `mapgl::add_h3t_source()`.
  - canonical SQL in `inst/sql/`; server build driver in
    `data-raw/build_obis_h3_duckdb.R`.

# obisindicators 0.0.2

* Renamed functions for consistency:
  - `calc_es50()` -> `calc_indicators()`
  - `gmap_metric()` -> `gmap_indicator()`
* Fixed `gmap_indicator()` to use default Robinson projection.
* Updated vignettes with name changes and use of "indicators" over "metrics".
* Supplemented documentation for `calc_indicators()` with expected input and output columns to data frame.
* Added documentation for `occ_fk` and `occ_1960s` to `occ_2010s`
* Made generation of occ_* datasets more reproducible with `set.seed()` and sampled versions of dataset to minimize file size on Github in `data-raw/occ.R`.

# obisindicators 0.0.1

* Added a `NEWS.md` file to track changes to the package.
