# Build the OBIS H3 DuckDB store

Reads OBIS occurrences, bins them to H3 cells, and writes an
authoritative DuckDB file with two layers consumed by the `h3t` tile
service:

## Usage

``` r
build_obis_h3_duckdb(
  src,
  path_duckdb,
  region_bbox = NULL,
  esn = 50L,
  s3_region = "us-east-1",
  s3_anonymous = TRUE,
  memory_limit = NULL,
  threads = NULL,
  temp_dir = NULL,
  max_temp_dir_size = NULL,
  overwrite = TRUE
)
```

## Arguments

- src:

  occurrence source. Either a `data.frame` of occurrences, or a
  character vector of parquet path(s)/glob(s) readable by DuckDB (e.g.
  `"s3://obis-open-data/occurrence/*.parquet"`). Must expose columns
  `decimalLongitude`, `decimalLatitude`, `species` and (optionally)
  `aphiaid`, `phylum`, `class`, `order`, `family`, `genus`, `date_year`,
  `records`, `dropped`, `absence`. Missing taxonomic columns are filled
  NULL.

- path_duckdb:

  output DuckDB file path.

- region_bbox:

  optional `c(lon_min, lat_min, lon_max, lat_max)` to restrict to a
  region (recommended for a first/demo build).

- esn:

  expected sample size for ES(n); default 50 (matches ES50).

- s3_region:

  AWS region for `s3://` sources (default `"us-east-1"`).

- s3_anonymous:

  use anonymous S3 access for public buckets (default TRUE).

- memory_limit:

  optional DuckDB `memory_limit` (e.g. `"10GB"`). Strongly recommended
  when `src` is a parquet/S3 glob: a global OBIS scan will otherwise
  exhaust RAM and can wedge the host. Leave a few GB headroom below
  physical RAM.

- threads:

  optional DuckDB thread cap (e.g. `2L`) to bound CPU/RAM.

- temp_dir:

  optional directory for DuckDB to spill to disk when it exceeds
  `memory_limit`. Needs ample free space (a global build can spill many
  GB); point it at a roomy volume, not `/tmp`.

- max_temp_dir_size:

  optional cap on DuckDB disk spill (e.g. `"20GB"`). Prevents a runaway
  aggregation from filling the volume and crashing the host. Set to
  comfortably below available free disk.

- overwrite:

  overwrite an existing `path_duckdb` (default TRUE).

## Value

`path_duckdb`, invisibly.

## Details

- `idx_h3(res, cell_id, n, sp, shannon, simpson, es, hex_prune)` —
  precomputed all-taxa indicators for resolutions 1-7 (fast default tile
  layers). Clustered by `(res, hex_prune, cell_id)` so the tile server
  prunes per tile.

- `idx_h3_taxon(rank, taxon, res, cell_id, n, sp, shannon, simpson, es)`
  — precomputed per-taxon indicators for ranks phylum/class/order, so a
  single-taxon map is as fast as the all-taxa layer. Clustered by
  `(rank, taxon, res)` for zonemap pruning.

- `occ_h3(res, cell_id, aphiaid, phylum, class, "order", family, genus, species, date_year, records, hex_prune)`
  — species-level counts at resolution tiers 3/5/7 for on-the-fly
  taxon/year/aphiaid-filtered queries. Clustered by
  `(res, hex_prune, cell_id)`, where `hex_prune` is the coarse H3 parent
  (`h3_cell_to_parent(cell_id, LEAST(res, H3T_PRUNE_RES))`). The h3t
  tile server derives each tile's covering res-`H3T_PRUNE_RES` cells
  from `z/x/y` and prunes the scan with `hex_prune IN (...)` — no
  client-side bbox needed; this is what makes live aphiaid/taxon tile
  maps fast at fine zoom.

The indicator math (ES50, Shannon, Simpson, richness) is the SQL
translation of
[`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md)
(`esn` = 50 by default), validated by the package tests.
