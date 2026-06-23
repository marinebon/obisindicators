# Build the authoritative OBIS H3 DuckDB store consumed by the MST `h3t` tile
# service (MarineSensitivity/server/h3t).
#
# DEFAULT = a cheap, local demo from the shipped South Atlantic data (no S3,
# ~10 s, trivial RAM) — the safe first step to validate the live h3t service.
#
# The S3 builds below are RESOURCE-HEAVY and OFF by default. The OBIS open-data
# bucket is one parquet file per dataset (NOT spatially partitioned), so any
# build that globs `*.parquet` scans the ENTIRE global dataset (hundreds of GB)
# regardless of `region_bbox`. On a small box that exhausts RAM/disk and can
# wedge the host. Only run them with memory_limit + temp_dir + threads, on a
# box with ample RAM and free disk.
#
# see also: build_obis_h3_duckdb() in R/h3t.R, and vignette("h3t").

librarian::shelf(DBI, duckdb, glue, quiet = TRUE)

# locate the package root and source ONLY R/h3t.R — build_obis_h3_duckdb() needs
# just DBI/duckdb/glue, not the full package (which also requires gsl + h3).
.argv <- commandArgs(trailingOnly = FALSE)
.file <- sub("^--file=", "", .argv[grep("^--file=", .argv)])
pkg_root <- if (length(.file) == 1) {
  normalizePath(file.path(dirname(.file), ".."))
} else {
  Sys.getenv("OBIS_PKG_ROOT", "/share/github/marinebon/obisindicators")
}
source(file.path(pkg_root, "R", "h3t.R"))

dir_obis <- Sys.getenv("OBIS_DIR", "/share/data/obis")
stamp    <- format(Sys.Date(), "v%Y%m%d")
dir.create(dir_obis, showWarnings = FALSE, recursive = TRUE)

# ---- DEFAULT: demo store from shipped South Atlantic data (local, fast) ----
# ~1M rows, no S3. occ_SAtlantic lacks taxonomic columns, so taxon filtering is
# limited to `species`; richness / Shannon / ES50 / #records all work.
load(file.path(pkg_root, "data", "occ_SAtlantic.rda"))   # -> occ_SAtlantic
path_demo <- file.path(dir_obis, glue("obis_h3_satlantic_{stamp}.duckdb"))
build_obis_h3_duckdb(occ_SAtlantic, path_demo)

# activate it for the service (atomic-ish symlink), then start h3t + h3tcache:
link <- file.path(dir_obis, "obis_h3.duckdb")
unlink(link); file.symlink(path_demo, link)
message("symlinked ", link, " -> ", path_demo)
#   cd /share/github/MarineSensitivity/server
#   docker compose up -d --build h3t h3tcache
#   curl -s http://localhost:8889/h3t/health | jq .

# ===========================================================================
# S3 BUILDS — OFF by default. DO NOT run on msens1 (t2.xlarge, 16 GB RAM,
# /share ~16 GB free) without freeing/adding disk and ideally resizing to a
# high-RAM instance first. Always pass memory_limit + temp_dir + threads.
# ===========================================================================

# ---- OPTION A: a few specific OBIS datasets (cheap, real taxa) -------------
# Reads ONLY the listed files (full phylum/class/aphiaid), not the whole bucket.
# Find dataset UUIDs via the obis-open-data bucket listing / https://obis.org.
if (FALSE) {
  uuids <- c("00017595-e015-4ec6-bf8a-b013e0dca521")  # example; add a handful
  src   <- sprintf("s3://obis-open-data/occurrence/%s.parquet", uuids)
  build_obis_h3_duckdb(
    src, file.path(dir_obis, glue("obis_h3_sample_{stamp}.duckdb")),
    memory_limit = "10GB", threads = 2L, temp_dir = file.path(dir_obis, "tmp"))
}

# ---- OPTION B: global build (needs a big box + lots of free disk) ---------
if (FALSE) {
  build_obis_h3_duckdb(
    src          = "s3://obis-open-data/occurrence/*.parquet",
    path_duckdb  = file.path(dir_obis, glue("obis_h3_global_{stamp}.duckdb")),
    memory_limit = "10GB", threads = 2L,
    temp_dir     = file.path(dir_obis, "tmp"))   # can spill many GB
  # release swap + cache flush (clients pass &release={stamp}):
  #   ln -sf .../obis_h3_global_{stamp}.duckdb /share/data/obis/obis_h3.duckdb
  #   docker compose restart h3t
  #   docker compose exec h3tcache varnishadm 'ban req.url ~ "^/h3t/"'
}
