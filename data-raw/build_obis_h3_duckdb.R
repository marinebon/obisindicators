# Build the authoritative OBIS H3 DuckDB store consumed by the MST `h3t` tile
# service (MarineSensitivity/server/h3t). Run on the MST server, where /share
# is mounted and S3 bandwidth is good. Streams OBIS open-data geoparquet via
# DuckDB httpfs (no full download) — this can take a while at global scope.
#
# see also: build_obis_h3_duckdb() in R/h3t.R, and vignette("h3t").

librarian::shelf(DBI, duckdb, glue, quiet = TRUE)
devtools::load_all(here::here())  # or library(obisindicators)

dir_obis  <- "/share/data/obis"
stamp     <- format(Sys.Date(), "v%Y%m%d")
obis_glob <- "s3://obis-open-data/occurrence/*.parquet"

# --- Phase 1: demo region first (cheap; proves the pipeline) ---------------
# South Atlantic bbox, matching obisindicators::occ_SAtlantic, as a default
# demo region. c(lon_min, lat_min, lon_max, lat_max).
region_satlantic <- c(-69.6008, -60, 20.0091, 0.0751)

path_region <- file.path(dir_obis, glue("obis_h3_satlantic_{stamp}.duckdb"))
build_obis_h3_duckdb(
  src         = obis_glob,
  path_duckdb = path_region,
  region_bbox = region_satlantic)

# point the service at the region build for the first demo:
#   ln -sf {path_region} /share/data/obis/obis_h3.duckdb
#   (cd /share/github/MarineSensitivity/server && docker compose up -d --build h3t h3tcache)

# --- Phase 2: global build (expensive; full OBIS scan) ---------------------
if (FALSE) {
  path_global <- file.path(dir_obis, glue("obis_h3_global_{stamp}.duckdb"))
  build_obis_h3_duckdb(
    src         = obis_glob,
    path_duckdb = path_global)
  # release swap + cache flush (clients pass &release={stamp}):
  #   ln -sf {path_global} /share/data/obis/obis_h3.duckdb
  #   docker compose restart h3t
  #   docker compose exec h3tcache varnishadm 'ban req.url ~ "^/h3t/"'
}
