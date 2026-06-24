# Build the authoritative OBIS H3 DuckDB store consumed by the MST `h3t` tile
# service (MarineSensitivity/server/h3t).
#
# Auto-detects what to build:
#   * if a local OBIS parquet mirror exists at $OBIS_DIR/occurrence/*.parquet
#     -> GLOBAL build from those files (no S3 at build time);
#   * otherwise -> a cheap LOCAL demo from the shipped South Atlantic data.
#
# Populate the mirror once with (frees you from re-streaming S3 each build):
#   aws s3 sync --no-sign-request \
#     s3://obis-open-data/occurrence/ /share/data/obis/occurrence/
#
# Resource caps (DuckDB memory_limit / threads / disk-spill temp_dir) keep the
# global build within bounds on a modest box — OBIS open-data is one parquet per
# dataset (not spatially partitioned), so a global aggregation must spill, not
# hold everything in RAM. Tune via env for the host.
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
dir_occ  <- file.path(dir_obis, "occurrence")        # local parquet mirror
stamp    <- format(Sys.Date(), "v%Y%m%d")
dir.create(dir_obis, showWarnings = FALSE, recursive = TRUE)

# resource caps (safe defaults for a ~16 GB box; override via env)
mem_limit <- Sys.getenv("OBIS_MEMORY_LIMIT", "4GB")
threads   <- as.integer(Sys.getenv("OBIS_THREADS", "2"))
temp_dir  <- file.path(dir_obis, "tmp")

n_local <- length(Sys.glob(file.path(dir_occ, "*.parquet")))

if (n_local > 0) {
  # ---- GLOBAL build from the local parquet mirror -------------------------
  message(glue("building GLOBAL store from {n_local} parquet files in {dir_occ}"))
  message(glue("  caps: memory_limit={mem_limit}, threads={threads}, ",
               "temp_dir={temp_dir}"))
  path_out <- file.path(dir_obis, glue("obis_h3_global_{stamp}.duckdb"))
  build_obis_h3_duckdb(
    src          = file.path(dir_occ, "*.parquet"),
    path_duckdb  = path_out,
    memory_limit = mem_limit,
    threads      = threads,
    temp_dir     = temp_dir)
} else {
  # ---- DEMO fallback: shipped South Atlantic data (local, no S3) ----------
  # ~1M rows, ~15 s. occ_SAtlantic lacks taxonomic columns, so taxon filtering
  # is limited to `species`; richness / Shannon / ES50 / #records all work.
  message(glue("no parquet in {dir_occ}; building South Atlantic DEMO store"))
  load(file.path(pkg_root, "data", "occ_SAtlantic.rda"))   # -> occ_SAtlantic
  path_out <- file.path(dir_obis, glue("obis_h3_satlantic_{stamp}.duckdb"))
  build_obis_h3_duckdb(occ_SAtlantic, path_out)
}

# ---- activate for the h3t service (atomic-ish symlink) --------------------
link <- file.path(dir_obis, "obis_h3.duckdb")
unlink(link); file.symlink(path_out, link)
message("symlinked ", link, " -> ", path_out)
cat("\nNext, on the server:\n",
    "  cd /share/github/MarineSensitivity/server\n",
    "  docker compose restart h3t\n",
    "  docker compose exec h3tcache varnishadm 'ban req.url ~ \"^/h3t/\"'\n",
    "  curl -s http://localhost:8889/h3t/health | jq .\n", sep = "")
