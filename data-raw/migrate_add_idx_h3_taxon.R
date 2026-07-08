#!/usr/bin/env Rscript
# One-off migration: add the precomputed `idx_h3_taxon` layer to an EXISTING
# obis_h3 DuckDB store, computed from the store's own `occ_h3` table.
#
# This does NOT re-read OBIS from S3, so it is NOT the OOM-risky path that
# build_obis_h3_duckdb() takes on a global glob — it only aggregates a local
# 8-28M-row table (bounded by memory_limit + temp_dir spill). It writes a NEW
# file so the live read-only store is untouched until you swap the symlink.
#
# The idx_h3_taxon math is a copy of obisindicators:::.h3t_idx_taxon_sql() so
# this script stays self-contained (no source()/library of the package needed).
#
# Usage:
#   Rscript migrate_add_idx_h3_taxon.R <in.duckdb> <out.duckdb> [--cluster-occ]
# Flags:
#   --cluster-occ       also sort occ_h3 by (res, taxonomy) so a taxon-filtered
#                       LIVE query prunes row-groups (zonemaps). Rewrites all rows.
#   --only-cluster-occ  ONLY cluster occ_h3; skip the idx_h3_taxon build (use on a
#                       store that already has idx_h3_taxon, to avoid rebuilding it).
# Env (optional caps): DUCKDB_MEMORY_LIMIT (8GB), DUCKDB_THREADS (4),
#   DUCKDB_TEMP_DIR (<dir(out)>/duckdb_tmp)

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2)
  stop("usage: migrate_add_idx_h3_taxon.R <in.duckdb> <out.duckdb> ",
       "[--cluster-occ] [--only-cluster-occ]")
in_db        <- args[1]
out_db       <- args[2]
only_cluster <- "--only-cluster-occ" %in% args   # cluster occ_h3, skip idx build
cluster_occ  <- only_cluster || "--cluster-occ" %in% args
stopifnot(file.exists(in_db))
if (file.exists(out_db)) stop("out.duckdb already exists: ", out_db)

RANKS <- c("phylum", "class", "order")   # H3T_IDX_RANKS
RES   <- 1:7                             # H3T_RES_IDX  (base tier = 7)
ESN   <- 50L

# per-(rank, res) INSERT — mirrors obisindicators:::.h3t_idx_taxon_sql()
idx_taxon_sql <- function(rank, r, esn = ESN) {
  col <- sprintf('"%s"', rank)           # quote reserved words (e.g. "order")
  sprintf("
    INSERT INTO idx_h3_taxon
    WITH src AS (
      SELECT %1$s AS taxon,
             CAST(h3_cell_to_parent(cell_id, %2$d) AS BIGINT) AS cell_id,
             species, SUM(records) AS ni
      FROM occ_h3 WHERE res = 7 AND %1$s IS NOT NULL
      GROUP BY 1, 2, 3),
    tot AS (
      SELECT taxon, cell_id, SUM(ni) AS n FROM src GROUP BY taxon, cell_id),
    per AS (
      SELECT s.taxon, s.cell_id, s.ni, t.n,
        CASE
          WHEN t.n - s.ni >= %3$d THEN 1 - exp(
                 lgamma(t.n - s.ni + 1) + lgamma(t.n - %3$d + 1)
               - lgamma(t.n - s.ni - %3$d + 1) - lgamma(t.n + 1))
          WHEN t.n >= %3$d THEN 1
          ELSE NULL END AS esi
      FROM src s JOIN tot t USING (taxon, cell_id))
    SELECT '%4$s' AS rank, taxon, %2$d AS res, cell_id,
      ANY_VALUE(n)                                AS n,
      COUNT(*)                                    AS sp,
      -SUM((ni::DOUBLE / n) * ln(ni::DOUBLE / n)) AS shannon,
      SUM((ni::DOUBLE / n) * (ni::DOUBLE / n))    AS simpson,
      SUM(esi)                                    AS es
    FROM per GROUP BY taxon, cell_id;",
    col, r, esn, rank)
}

stopifnot(requireNamespace("DBI", quietly = TRUE),
          requireNamespace("duckdb", quietly = TRUE))

message("copying ", in_db, " -> ", out_db, " ...")
if (!file.copy(in_db, out_db)) stop("copy failed (disk space?): ", out_db)

con <- DBI::dbConnect(duckdb::duckdb(), dbdir = out_db, read_only = FALSE)
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
DBI::dbExecute(con, "INSTALL h3 FROM community; LOAD h3;")
DBI::dbExecute(con, "SET preserve_insertion_order = false;")
DBI::dbExecute(con, sprintf("SET memory_limit = '%s';",
                            Sys.getenv("DUCKDB_MEMORY_LIMIT", "8GB")))
DBI::dbExecute(con, sprintf("SET threads = %s;",
                            Sys.getenv("DUCKDB_THREADS", "4")))
tmp <- Sys.getenv("DUCKDB_TEMP_DIR", file.path(dirname(out_db), "duckdb_tmp"))
dir.create(tmp, showWarnings = FALSE, recursive = TRUE)
DBI::dbExecute(con, sprintf("SET temp_directory = '%s';", tmp))

# guard: the store must actually have occ_h3 to aggregate
have <- DBI::dbGetQuery(con, "
  SELECT COUNT(*) AS n FROM information_schema.tables
  WHERE table_schema = 'main' AND table_name = 'occ_h3'")$n
if (have < 1) stop("store has no occ_h3 table; nothing to aggregate: ", out_db)

if (only_cluster) {
  if (!DBI::dbExistsTable(con, "idx_h3_taxon"))
    warning("--only-cluster-occ: idx_h3_taxon not present in ", in_db)
  message("--only-cluster-occ: skipping idx_h3_taxon build")
} else {
  message("building idx_h3_taxon for ranks: ", paste(RANKS, collapse = ", "))
  DBI::dbExecute(con, "DROP TABLE IF EXISTS idx_h3_taxon;")
  DBI::dbExecute(con, "
    CREATE TABLE idx_h3_taxon (
      rank VARCHAR, taxon VARCHAR, res UTINYINT, cell_id BIGINT,
      n BIGINT, sp BIGINT, shannon DOUBLE, simpson DOUBLE, es DOUBLE);")
  for (rank in RANKS)
    for (r in RES) {
      message("  ", rank, " res ", r)
      DBI::dbExecute(con, idx_taxon_sql(rank, r))
    }
  # cluster by the lookup key so a (rank, taxon, res) filter prunes to a small scan
  DBI::dbExecute(con, "
    CREATE TABLE idx_h3_taxon_c AS
      SELECT * FROM idx_h3_taxon ORDER BY rank, taxon, res;")
  DBI::dbExecute(con, "DROP TABLE idx_h3_taxon;")
  DBI::dbExecute(con, "ALTER TABLE idx_h3_taxon_c RENAME TO idx_h3_taxon;")
}

if (cluster_occ) {
  message("clustering occ_h3 by (res, taxonomy) — rewrites all rows ...")
  DBI::dbExecute(con, '
    CREATE TABLE occ_h3_c AS
      SELECT * FROM occ_h3
      ORDER BY res, phylum, class, "order", family, genus, species;')
  DBI::dbExecute(con, "DROP TABLE occ_h3;")
  DBI::dbExecute(con, "ALTER TABLE occ_h3_c RENAME TO occ_h3;")
}

DBI::dbExecute(con, "CHECKPOINT;")
if (DBI::dbExistsTable(con, "idx_h3_taxon")) {
  s <- DBI::dbGetQuery(con,
    "SELECT COUNT(*) AS n_rows, COUNT(DISTINCT taxon) AS n_taxa FROM idx_h3_taxon")
  message(sprintf("idx_h3_taxon = %s rows across %s taxa",
                  format(s$n_rows, big.mark = ","), s$n_taxa))
}
message(sprintf("done -> %s%s", out_db,
                if (cluster_occ) " (occ_h3 clustered)" else ""))
