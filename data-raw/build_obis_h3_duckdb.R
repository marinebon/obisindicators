# Build the authoritative OBIS H3 DuckDB store for the MST `h3t` tile service.
#
# Always runs:  demo store from shipped occ_SAtlantic (~10 s, no S3).
# Auto-runs:    global store when /share/data/obis/occurrence/*.parquet exists
#               (populate with: aws s3 sync --no-sign-request
#                 s3://obis-open-data/occurrence/ /share/data/obis/occurrence/).
# Force S3:     OBIS_GLOBAL=true — skips local check, streams directly from S3
#               (slow, requires good S3 bandwidth; ~96 GB, ~6 900 parquets).
#
# Resource guards (both builds): memory_limit=10GB, threads=2, spill to
# temp_dir.  Adjust via OBIS_MEMORY / OBIS_THREADS / OBIS_TEMP_DIR env vars.
#
# After a successful global build the script:
#   1. Swaps obis_h3.duckdb symlink to the new store.
#   2. Restarts the h3t tile service (docker compose restart h3t).
#   3. Flushes the h3tcache (varnishadm ban).
#   4. Removes temp spill files.
#   Parquet source files are NOT deleted automatically; remove manually once
#   the new store is validated.
#
# see also: build_obis_h3_duckdb() in R/h3t.R, and vignette("h3t").

librarian::shelf(DBI, duckdb, glue, quiet = TRUE)

# locate the package root and source only R/h3t.R — build_obis_h3_duckdb()
# needs DBI/duckdb/glue only; full package load also requires gsl + h3 R pkg.
.argv    <- commandArgs(trailingOnly = FALSE)
.file    <- sub("^--file=", "", .argv[grep("^--file=", .argv)])
pkg_root <- if (length(.file) == 1) {
  normalizePath(file.path(dirname(.file), ".."))
} else {
  Sys.getenv("OBIS_PKG_ROOT", "/share/github/marinebon/obisindicators")
}
source(file.path(pkg_root, "R", "h3t.R"))

dir_obis  <- Sys.getenv("OBIS_DIR",      "/share/data/obis")
stamp     <- format(Sys.Date(), "v%Y%m%d")
mem_limit <- Sys.getenv("OBIS_MEMORY",   "10GB")
n_threads <- as.integer(Sys.getenv("OBIS_THREADS", "2"))
tmp_dir   <- Sys.getenv("OBIS_TEMP_DIR", file.path(dir_obis, "tmp"))
dir.create(dir_obis, showWarnings = FALSE, recursive = TRUE)

symlink_to <- function(target, link = file.path(dir_obis, "obis_h3.duckdb")) {
  unlink(link)
  file.symlink(target, link)
  message("symlink: ", link, " -> ", target)
}

# ---- 1. Demo store from shipped South Atlantic data (always) ---------------
load(file.path(pkg_root, "data", "occ_SAtlantic.rda"))
path_demo <- file.path(dir_obis, glue("obis_h3_satlantic_{stamp}.duckdb"))
build_obis_h3_duckdb(occ_SAtlantic, path_demo)
symlink_to(path_demo)
message("demo build complete. h3t serve: docker compose up -d --build h3t h3tcache")

# ---- 2. Global store (auto when local parquets present; or OBIS_GLOBAL=true) -
dir_occ_local <- file.path(dir_obis, "occurrence")
force_s3      <- isTRUE(as.logical(Sys.getenv("OBIS_GLOBAL", "false")))

has_local <- dir.exists(dir_occ_local) &&
  length(list.files(dir_occ_local, pattern = "\\.parquet$")) > 0

if (has_local || force_s3) {
  src_global <- if (has_local) {
    message("global build: using local parquets at ", dir_occ_local)
    file.path(dir_occ_local, "*.parquet")
  } else {
    message("global build: streaming from s3://obis-open-data/occurrence/")
    "s3://obis-open-data/occurrence/*.parquet"
  }

  path_global <- file.path(dir_obis, glue("obis_h3_global_{stamp}.duckdb"))
  build_obis_h3_duckdb(
    src          = src_global,
    path_duckdb  = path_global,
    memory_limit = mem_limit,
    threads      = n_threads,
    temp_dir     = tmp_dir)

  symlink_to(path_global)

  # restart service + flush Varnish cache
  server_dir <- "/share/github/MarineSensitivity/server"
  if (dir.exists(server_dir)) {
    system(glue("docker compose -f {server_dir}/docker-compose.yml restart h3t"))
    system(paste0(
      "docker compose -f ", server_dir, "/docker-compose.yml exec -T h3tcache ",
      "varnishadm 'ban req.url ~ \"^/h3t/\"'"))
  }

  # clean up spill files
  unlink(tmp_dir, recursive = TRUE)
  message("global build complete: ", path_global)
} else {
  message("no local parquets found at ", dir_occ_local,
          " — skipping global build.",
          "\n  To sync: aws s3 sync --no-sign-request",
          " s3://obis-open-data/occurrence/ ", dir_occ_local, "/",
          "\n  To force S3 stream: OBIS_GLOBAL=true Rscript ", .file[1])
}
