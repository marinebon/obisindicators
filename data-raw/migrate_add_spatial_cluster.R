#!/usr/bin/env Rscript
# One-off migration: add the coarse H3-parent prune key `hex_prune` and cluster
# `occ_h3` / `idx_h3` by (res, hex_prune, cell_id) in an EXISTING obis_h3 DuckDB
# store, so the `h3t` tile service can prune each tile to its covering
# res-H3T_PRUNE_RES cells (`hex_prune IN (...)`, derived server-side from z/x/y)
# instead of aggregating the whole res tier per tile. This is what makes live
# aphiaid/taxon (and all-taxa) tile maps fast at fine zoom. See
# build_obis_h3_duckdb() and H3T_PRUNE_RES.
#
# Supersedes the earlier lat/lng approach: if the input store carries `lat`/`lng`
# columns (from that interim build), they are dropped here. Builds a fresh store
# by ATTACHing the old one read-only and CTAS-ing each table (no S3/parquet
# re-read). `idx_h3_taxon` keeps its (rank, taxon, res) clustering; `taxon` is
# copied with its recursive-walk indexes recreated.
#
# Writes a NEW file so the live read-only store is untouched until you swap the
# symlink, e.g.:
#   ln -sfn /share/data/obis/obis_h3_global_..._hp.duckdb \
#           /share/data/obis/obis_h3.duckdb
#   cd .../server && docker compose build h3t && docker compose up -d h3t
#   docker compose exec -T h3tcache varnishadm 'ban req.url ~ "^/h3t/"'
#
# Usage:
#   Rscript migrate_add_spatial_cluster.R <in.duckdb> <out.duckdb>
# Env (optional caps): DUCKDB_MEMORY_LIMIT (8GB), DUCKDB_THREADS (4),
#   DUCKDB_TEMP_DIR (<dir(out)>/duckdb_tmp), DUCKDB_MAX_TEMP_DIR_SIZE (40GB).

H3T_PRUNE_RES <- 3L   # keep in sync with R/h3t.R + the server's PRUNE_RES

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2)
  stop("usage: migrate_add_spatial_cluster.R <in.duckdb> <out.duckdb>")
in_db  <- path.expand(args[1])
out_db <- path.expand(args[2])

stopifnot(file.exists(in_db))
if (file.exists(out_db)) stop("out.duckdb already exists: ", out_db)
stopifnot(requireNamespace("DBI", quietly = TRUE),
          requireNamespace("duckdb", quietly = TRUE),
          requireNamespace("glue", quietly = TRUE))

con <- DBI::dbConnect(duckdb::duckdb(), dbdir = out_db, read_only = FALSE)
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

DBI::dbExecute(con, "INSTALL h3 FROM community; LOAD h3;")
DBI::dbExecute(con, sprintf("SET memory_limit = '%s';",
                            Sys.getenv("DUCKDB_MEMORY_LIMIT", "8GB")))
DBI::dbExecute(con, sprintf("SET threads = %s;",
                            Sys.getenv("DUCKDB_THREADS", "4")))
tmp <- Sys.getenv("DUCKDB_TEMP_DIR", file.path(dirname(out_db), "duckdb_tmp"))
dir.create(tmp, showWarnings = FALSE, recursive = TRUE)
DBI::dbExecute(con, sprintf("SET temp_directory = '%s';", tmp))
DBI::dbExecute(con, sprintf("SET max_temp_directory_size = '%s';",
                            Sys.getenv("DUCKDB_MAX_TEMP_DIR_SIZE", "40GB")))

DBI::dbExecute(con, glue::glue("ATTACH '{in_db}' AS old (READ_ONLY);"))

old_tbls <- DBI::dbGetQuery(con,
  "SELECT table_name FROM information_schema.tables
   WHERE table_catalog = 'old' AND table_schema = 'main'")$table_name
has_tbl <- function(t) t %in% old_tbls
cols_of <- function(t, cat = "old") tolower(names(
  DBI::dbGetQuery(con, glue::glue("SELECT * FROM {cat}.{t} LIMIT 0"))))

stopifnot("old store missing occ_h3" = has_tbl("occ_h3"),
          "old store missing idx_h3" = has_tbl("idx_h3"))

# add hex_prune (coarse H3 parent) and cluster by (res, hex_prune, cell_id).
# drop any interim lat/lng columns. zonemaps live on stored columns, so the
# coarse parent is materialized here — an inline h3_cell_to_parent() can't prune.
prune_ctas <- function(tbl) {
  drop <- intersect(c("lat", "lng"), cols_of(tbl))
  excl <- if (length(drop)) sprintf(" EXCLUDE (%s)", paste(drop, collapse = ", ")) else ""
  add  <- if ("hex_prune" %in% cols_of(tbl)) "" else glue::glue(
    ", CAST(h3_cell_to_parent(cell_id, LEAST(res, {H3T_PRUNE_RES})) AS BIGINT) AS hex_prune")
  message("rewriting ", tbl, ": +hex_prune (res-", H3T_PRUNE_RES,
          "), clustered (res, hex_prune, cell_id)",
          if (length(drop)) paste0(", -", paste(drop, collapse = "/")) else "")
  DBI::dbExecute(con, glue::glue(
    "CREATE TABLE {tbl} AS
       SELECT *{excl}{add} FROM old.{tbl}
       ORDER BY res, hex_prune, cell_id;"))
}
prune_ctas("occ_h3")
prune_ctas("idx_h3")

# idx_h3_taxon: keep its (rank, taxon, res) lookup clustering (no spatial prune).
if (has_tbl("idx_h3_taxon")) {
  message("copying idx_h3_taxon (clustered rank, taxon, res) ...")
  DBI::dbExecute(con, "
    CREATE TABLE idx_h3_taxon AS
      SELECT * FROM old.idx_h3_taxon ORDER BY rank, taxon, res;")
}

# taxon: copy + recreate the recursive-walk indexes (CTAS does not carry them).
if (has_tbl("taxon")) {
  message("copying taxon + recreating indexes ...")
  DBI::dbExecute(con, "CREATE TABLE taxon AS SELECT * FROM old.taxon;")
  DBI::dbExecute(con, "CREATE INDEX taxon_parent_idx  ON taxon(parentNameUsageID);")
  DBI::dbExecute(con, "CREATE INDEX taxon_taxonid_idx ON taxon(taxonID);")
}

DBI::dbExecute(con, "DETACH old;")
DBI::dbExecute(con, "CHECKPOINT;")

# verify: hex_prune present, no lat/lng, row counts
for (t in c("occ_h3", "idx_h3")) {
  cc <- cols_of(t, cat = "main")
  stopifnot("hex_prune" %in% cc, !any(c("lat", "lng") %in% cc))
  n <- DBI::dbGetQuery(con, glue::glue("SELECT COUNT(*) n FROM {t}"))$n
  message(sprintf("  %-13s %s rows, hex_prune OK", t, format(n, big.mark = ",")))
}
message("done -> ", out_db)
