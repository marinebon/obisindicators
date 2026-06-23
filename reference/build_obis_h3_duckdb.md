# Build the OBIS H3 DuckDB store

Reads OBIS occurrences, bins them to H3 cells, and writes an
authoritative DuckDB file with two layers consumed by the `h3t` tile
service:

- `idx_h3(res, cell_id, n, sp, shannon, simpson, es)` — precomputed
  all-taxa indicators for resolutions 1-7 (fast default tile layers).

- `occ_h3(res, cell_id, aphiaid, phylum, class, "order", family, genus, species, date_year, records)`
  — species-level counts at resolution tiers 3/5/7 for on-the-fly
  taxon/year-filtered queries.

## Usage

``` r
build_obis_h3_duckdb(
  src,
  path_duckdb,
  region_bbox = NULL,
  esn = 50L,
  s3_region = "us-east-1",
  s3_anonymous = TRUE,
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

- overwrite:

  overwrite an existing `path_duckdb` (default TRUE).

## Value

`path_duckdb`, invisibly.

## Details

The indicator math (ES50, Shannon, Simpson, richness) is the SQL
translation of
[`calc_indicators()`](http://marinebon.org/obisindicators/reference/calc_indicators.md)
(`esn` = 50 by default), validated by the package tests.
