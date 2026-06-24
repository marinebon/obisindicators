# Serving OBIS indicators as H3 hexagon tiles (h3t)

This article shows how to serve
[obisindicators](https://github.com/marinebon/obisindicators)
biodiversity metrics — ES50, Shannon, species richness, number of
records — as zoomable **H3 hexagon map tiles**, computed on demand from
a read-only SQL query against a cloud-native
[DuckDB](https://duckdb.org) store. It realizes the “biodiversity by hex
(OBIS)” pattern of Best et al. (§4.4): *a map tile is just a
viewport-sized projection of a read-only query against an authoritative
store.*

The serving half is the [`h3t` tile
factory](https://github.com/CalCOFI/api-h3t-py) (vendored into the [MST
server](https://github.com/MarineSensitivity/server) as `server/h3t`):
it base64-decodes a `SELECT` from the tile URL, validates it is
read-only and projects exactly `cell_id, value, n`, substitutes the
`{{res}}` placeholder with the tile’s H3 resolution, and returns
[h3j](https://github.com/INSPIDE/h3j-h3t) JSON for MapLibre
([`mapgl::add_h3t_source()`](https://walker-data.com/mapgl/reference/add_h3t_source.html)).

``` r

library(obisindicators)
```

## 1. Build the authoritative store

[`build_obis_h3_duckdb()`](http://marinebon.org/obisindicators/reference/build_obis_h3_duckdb.md)
streams [OBIS open-data](https://github.com/iobis/obis-open-data)
geoparquet via DuckDB `httpfs` (byte-range, no full download), bins
occurrences to H3, and writes two layers:

- `idx_h3` — precomputed **all-taxa** indicators (ES50, Shannon,
  Simpson, richness, n) for resolutions 1–7 (fast default tile layers).
- `occ_h3` — **species-level** counts at resolution tiers 3/5/7, for
  on-the-fly **taxon/year-filtered** queries.

The indicator math is the SQL translation of
\[[`calc_indicators()`](http://marinebon.org/obisindicators/reference/calc_indicators.md)\]
(`esn = 50`), pinned to that R reference by the package tests.

``` r

# a demo region first (cheap) — South Atlantic, matching occ_SAtlantic
build_obis_h3_duckdb(
  src         = "s3://obis-open-data/occurrence/*.parquet",
  path_duckdb = "/share/data/obis/obis_h3.duckdb",
  region_bbox = c(-69.6008, -60, 20.0091, 0.0751))  # lon_min,lat_min,lon_max,lat_max
```

``` r

# the full global build (expensive S3 scan); drop region_bbox
build_obis_h3_duckdb(
  src         = "s3://obis-open-data/occurrence/*.parquet",
  path_duckdb = "/share/data/obis/obis_h3_global.duckdb")
```

You can also build a small local store from shipped data to develop
against:

``` r

build_obis_h3_duckdb(occ_SAtlantic, "obis_h3.duckdb")
```

## 2. Deploy the tile service

On the MST server the store is registered with the `h3t` service
(`H3T_DBS=obis:/share/data/obis/obis_h3.duckdb`) and fronted by
Varnish + Caddy:

``` sh
cd /share/github/MarineSensitivity/server
docker compose up -d --build h3t h3tcache   # -> https://h3t.marinesensitivity.org
```

## 3. Compose tile queries

[`obis_h3t_sql()`](http://marinebon.org/obisindicators/reference/obis_h3t_sql.md)
generates the validated `SELECT`. With no filter it reads the fast
precomputed layer; with a `taxon`/`years` filter it computes the
indicator live from the species store.

``` r

library(obisindicators)
#> Warning: replacing previous import 'h3::compact' by 'purrr::compact' when
#> loading 'obisindicators'

# default ES50 (all taxa) — precomputed, fast
obis_h3t_sql("es")
#> [1] "SELECT cell_id, es AS value, n FROM idx_h3 WHERE res = LEAST({{res}}, 7)"

# species richness for seabirds since 2000 — computed on the fly
cat(obis_h3t_sql("sp", taxon = list(class = "Aves"), years = c(2000, NA)))
#> WITH src AS (
#>   SELECT CAST(h3_cell_to_parent(cell_id, LEAST({{res}}, 7)) AS BIGINT) AS cell_id,
#>          species, SUM(records) AS ni
#>   FROM occ_h3
#>   WHERE res = CASE WHEN LEAST({{res}}, 7) <= 3 THEN 3 WHEN LEAST({{res}}, 7) <= 5 THEN 5 ELSE 7 END
#>     AND "class" = 'Aves'
#>         AND date_year >= 2000
#>   GROUP BY 1, 2)
#> SELECT cell_id, COUNT(*) AS value, SUM(ni) AS n FROM src GROUP BY cell_id
```

[`obis_h3t_url()`](http://marinebon.org/obisindicators/reference/obis_h3t_url.md)
base64-encodes the SQL into a `?q=` tile URL (and safely percent-encodes
it, so `+`/`/` in the base64 survive query parsing):

``` r

obis_h3t_url(
  base_url  = "h3tiles://h3tcache.marinesensitivity.org/h3t/{z}/{x}/{y}.h3t",
  indicator = "es",
  release   = "v20260623")
#> [1] "h3tiles://h3tcache.marinesensitivity.org/h3t/{z}/{x}/{y}.h3t?q=U0VMRUNUIGNlbGxfaWQsIGVzIEFTIHZhbHVlLCBuIEZST00gaWR4X2gzIFdIRVJFIHJlcyA9IExFQVNUKHt7cmVzfX0sIDcp&release=v20260623"
```

Inspect the value distribution (for color-ramp breaks) at the stats
endpoint:

``` r

u <- obis_h3t_url(
  base_url  = "https://h3tcache.marinesensitivity.org/h3t/stats",
  indicator = "es")
jsonlite::fromJSON(u)  # {min, max, p02, p98, n}
```

## 4. Map it with MapLibre

``` r

library(mapgl)

tiles_es50 <- obis_h3t_url(
  base_url  = "h3tiles://h3tcache.marinesensitivity.org/h3t/{z}/{x}/{y}.h3t",
  indicator = "es",
  release   = "v20260623")

maplibre(center = c(-25, -30), zoom = 3) |>
  add_h3t_source(id = "obis_es50", tiles = tiles_es50) |>
  add_fill_layer(
    id           = "obis_es50",
    source       = "obis_es50",
    source_layer = "obis_es50",
    fill_color   = interpolate(
      column = "value", values = c(1, 50),
      stops  = c("#440154", "#21908C", "#FDE725")),  # viridis
    fill_opacity = 0.8)
```

Swap `indicator = "sp"` for richness, or add a `taxon`/`years` filter to
drive a dropdown — each choice rebuilds the SQL encoded in the tile URL,
and the same authoritative store answers every query.
