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

dir_obis      <- Sys.getenv("OBIS_DIR",      "/share/data/obis")
stamp         <- format(Sys.Date(), "v%Y%m%d")
mem_limit     <- Sys.getenv("OBIS_MEMORY",   "7GB")   # stays under 8GB docker hard cap
n_threads     <- as.integer(Sys.getenv("OBIS_THREADS", "2"))
tmp_dir       <- Sys.getenv("OBIS_TEMP_DIR", file.path(dir_obis, "tmp"))
max_tmp       <- Sys.getenv("OBIS_MAX_TEMP", "20GB")  # cap disk spill to prevent crash
dir.create(dir_obis, showWarnings = FALSE, recursive = TRUE)

symlink_to <- function(target, link = file.path(dir_obis, "obis_h3.duckdb")) {
  unlink(link)
  file.symlink(target, link)
  message("symlink: ", link, " -> ", target)
}

# bake the WoRMS `taxon` table (from build_taxon_parquet.R) into a freshly built
# store so the h3t service / API can resolve arbitrary-rank children taxa
# (see R/taxon.R). No-op with a hint when the parquet is absent — the existing
# global store can be upgraded separately via data-raw/migrate_add_taxon.R.
taxon_pq <- Sys.getenv("OBIS_TAXON_PARQUET",
                       file.path(dirname(dir_obis), "derived", "taxon.parquet"))
bake_taxon <- function(path_duckdb) {
  if (!file.exists(taxon_pq)) {
    message("no taxon.parquet at ", taxon_pq,
            " — skipping taxon bake (run build_taxon_parquet.R then ",
            "migrate_add_taxon.R to add children-taxa support).")
    return(invisible())
  }
  message("baking taxon into ", path_duckdb, " from ", taxon_pq, " ...")
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = path_duckdb, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "DROP TABLE IF EXISTS taxon;")
  DBI::dbExecute(con, glue("
    CREATE TABLE taxon AS
      SELECT CAST(taxonID AS BIGINT) AS taxonID,
             CAST(parentNameUsageID AS BIGINT) AS parentNameUsageID,
             CAST(acceptedNameUsageID AS BIGINT) AS acceptedNameUsageID,
             scientificName, taxonRank, taxonomicStatus
      FROM read_parquet('{taxon_pq}') WHERE taxonID IS NOT NULL;"))
  DBI::dbExecute(con, "CREATE INDEX taxon_parent_idx  ON taxon(parentNameUsageID);")
  DBI::dbExecute(con, "CREATE INDEX taxon_taxonid_idx ON taxon(taxonID);")
  DBI::dbExecute(con, "CHECKPOINT;")
  message("  taxon baked: ",
          format(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM taxon")$n,
                 big.mark = ","), " rows")
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
    src              = src_global,
    path_duckdb      = path_global,
    memory_limit     = mem_limit,
    threads          = n_threads,
    temp_dir         = tmp_dir,
    max_temp_dir_size = max_tmp)

  bake_taxon(path_global)   # add WoRMS taxon table for children-taxa queries
  symlink_to(path_global)

  # This script BUILDS; it does not deploy. It used to shell out to
  # `docker compose restart h3t` here, which is wrong in two ways: this runs
  # inside the plumber container, which has no docker CLI (the Jun-2026 global
  # build logged "sh: 1: docker: not found" twice and still exited 0), and
  # system() return codes were never checked, so even where docker DID exist a
  # failed restart was invisible. h3t holds the store's file handle open, so a
  # skipped restart leaves the service quietly serving the PREVIOUS store while
  # the symlink says otherwise — the worst kind of failure, a successful-looking
  # no-op.
  #
  # Deployment now belongs to data-raw/deploy_obis_h3.sh, which runs on the HOST
  # (where docker exists) and verifies the restart actually took effect. Drop a
  # sentinel so a directly-invoked build can't be mistaken for a deployed one.
  sentinel <- file.path(dir_obis, "RESTART_REQUIRED")
  writeLines(c(
    paste0("built: ",  path_global),
    paste0("at: ",     format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")),
    "h3t is still serving the PREVIOUS store until it is restarted.",
    "Deploy with:  data-raw/deploy_obis_h3.sh --skip-sync --skip-build",
    "(that script restarts h3t, flushes Varnish, and VERIFIES the swap took)"),
    sentinel)
  message(strrep("=", 72), "\n",
          "BUILD COMPLETE - NOT YET DEPLOYED\n",
          "h3t holds the old store's file handle and will keep serving it.\n",
          "Run on the HOST:  data-raw/deploy_obis_h3.sh --skip-sync --skip-build\n",
          "Sentinel: ", sentinel, "\n", strrep("=", 72))

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
