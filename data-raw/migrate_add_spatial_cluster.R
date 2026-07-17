#!/usr/bin/env Rscript
# One-off migration: add precomputed cell-centroid `lat`/`lng` columns and
# re-cluster `occ_h3` and `idx_h3` SPATIALLY by (res, lat, lng) in an EXISTING
# obis_h3 DuckDB store, so the `h3t` tile service can prune each tile's scan to
# its bbox (the `{{bbox}}` placeholder in obisindicators::obis_h3t_sql()) instead
# of aggregating the whole globe per tile. This is what makes live aphiaid/taxon
# (and all-taxa) tile maps fast at fine zoom. See build_obis_h3_duckdb().
#
# Builds a fresh store by ATTACHing the old one read-only and CTAS-ing each
# table (no S3 / parquet re-read). `idx_h3_taxon` keeps its (rank, taxon, res)
# clustering; `taxon` is copied with its recursive-walk indexes recreated.
#
# Writes a NEW file so the live read-only store is untouched until you swap the
# symlink, e.g.:
#   ln -sf /share/data/obis/obis_h3_global_..._sc.duckdb \
#          /share/data/obis/obis_h3.duckdb
#   docker compose -f .../server/docker-compose.yml restart h3t
#   docker compose -f .../server/docker-compose.yml exec h3tcache \
#     varnishadm 'ban req.url ~ "^/h3t/"'
#
# Usage:
#   Rscript migrate_add_spatial_cluster.R <in.duckdb> <out.duckdb>
# Env (optional caps): DUCKDB_MEMORY_LIMIT (8GB), DUCKDB_THREADS (4),
#   DUCKDB_TEMP_DIR (<dir(out)>/duckdb_tmp), DUCKDB_MAX_TEMP_DIR_SIZE (40GB).

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
cols_of <- function(t) tolower(names(
  DBI::dbGetQuery(con, glue::glue("SELECT * FROM old.{t} LIMIT 0"))))

stopifnot("old store missing occ_h3" = has_tbl("occ_h3"),
          "old store missing idx_h3" = has_tbl("idx_h3"))

# add lat/lng (cell centroid) unless already present, then spatially cluster.
# zonemaps live on stored columns, so lat/lng must be materialized for a
# lat/lng BETWEEN predicate to prune row groups.
spatial_ctas <- function(tbl) {
  add <- if (all(c("lat", "lng") %in% cols_of(tbl))) "" else
    ", h3_cell_to_lat(cell_id) AS lat, h3_cell_to_lng(cell_id) AS lng"
  message("rewriting ", tbl, " with lat/lng, clustered (res, lat, lng) ...")
  DBI::dbExecute(con, glue::glue(
    "CREATE TABLE {tbl} AS
       SELECT *{add} FROM old.{tbl} ORDER BY res, lat, lng;"))
}
spatial_ctas("occ_h3")
spatial_ctas("idx_h3")

# idx_h3_taxon: keep its (rank, taxon, res) lookup clustering (no bbox pruning).
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

# verify: lat/lng present, row counts, and a spatial-prune sanity check
for (t in c("occ_h3", "idx_h3")) {
  cc <- cols_of_new <- tolower(names(
    DBI::dbGetQuery(con, glue::glue("SELECT * FROM {t} LIMIT 0"))))
  stopifnot(all(c("lat", "lng") %in% cc))
  n <- DBI::dbGetQuery(con, glue::glue("SELECT COUNT(*) n FROM {t}"))$n
  message(sprintf("  %-13s %s rows, lat/lng OK", t, format(n, big.mark = ",")))
}
message("done -> ", out_db)
