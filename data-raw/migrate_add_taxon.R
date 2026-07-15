#!/usr/bin/env Rscript
# One-off migration: bake a WoRMS `taxon` table into an EXISTING obis_h3 DuckDB
# store so the `h3t` service (and the API) can resolve arbitrary-rank children
# taxa — filtering occ_h3.aphiaid by the descendant AphiaIDs of any taxon, via
# a recursive walk over taxon.parentNameUsageID. See obis_taxon_children() and
# obis_h3t_sql(aphiaid=). The `taxon` subset comes from build_taxon_parquet.R.
#
# Writes a NEW file so the live read-only store is untouched until you swap the
# symlink, e.g.:
#   ln -sf /share/data/obis/obis_h3_global_taxon_vYYYYMMDD.duckdb \
#          /share/data/obis/obis_h3.duckdb
#   docker compose -f .../server/docker-compose.yml restart h3t
#   docker compose -f .../server/docker-compose.yml exec h3tcache \
#     varnishadm 'ban req.url ~ "^/h3t/"'
#
# Usage:
#   Rscript migrate_add_taxon.R <in.duckdb> <out.duckdb> [taxon.parquet]
# Env (optional caps): DUCKDB_MEMORY_LIMIT (8GB), DUCKDB_THREADS (4),
#   DUCKDB_TEMP_DIR (<dir(out)>/duckdb_tmp), OBIS_TAXON_PARQUET.

args   <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2)
  stop("usage: migrate_add_taxon.R <in.duckdb> <out.duckdb> [taxon.parquet]")
in_db    <- args[1]
out_db   <- args[2]
is_server <- Sys.info()[["sysname"]] == "Linux"
dir_data  <- ifelse(is_server, "/share/data", "~/My Drive/projects/msens/data")
taxon_pq <- if (length(args) >= 3) args[3] else Sys.getenv(
  "OBIS_TAXON_PARQUET", file.path(dir_data, "derived", "taxon.parquet"))
taxon_pq <- path.expand(taxon_pq)

stopifnot(file.exists(in_db), file.exists(taxon_pq))
if (file.exists(out_db)) stop("out.duckdb already exists: ", out_db)
stopifnot(requireNamespace("DBI", quietly = TRUE),
          requireNamespace("duckdb", quietly = TRUE))

message("copying ", in_db, " -> ", out_db, " ...")
if (!file.copy(in_db, out_db)) stop("copy failed (disk space?): ", out_db)

con <- DBI::dbConnect(duckdb::duckdb(), dbdir = out_db, read_only = FALSE)
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
DBI::dbExecute(con, sprintf("SET memory_limit = '%s';",
                            Sys.getenv("DUCKDB_MEMORY_LIMIT", "8GB")))
DBI::dbExecute(con, sprintf("SET threads = %s;",
                            Sys.getenv("DUCKDB_THREADS", "4")))
tmp <- Sys.getenv("DUCKDB_TEMP_DIR", file.path(dirname(out_db), "duckdb_tmp"))
dir.create(tmp, showWarnings = FALSE, recursive = TRUE)
DBI::dbExecute(con, sprintf("SET temp_directory = '%s';", tmp))

message("loading taxon from ", taxon_pq, " ...")
DBI::dbExecute(con, "DROP TABLE IF EXISTS taxon;")
DBI::dbExecute(con, sprintf("
  CREATE TABLE taxon AS
    SELECT
      CAST(taxonID             AS BIGINT)  AS taxonID,
      CAST(parentNameUsageID   AS BIGINT)  AS parentNameUsageID,
      CAST(acceptedNameUsageID AS BIGINT)  AS acceptedNameUsageID,
      CAST(scientificName      AS VARCHAR) AS scientificName,
      CAST(taxonRank           AS VARCHAR) AS taxonRank,
      CAST(taxonomicStatus     AS VARCHAR) AS taxonomicStatus
    FROM read_parquet('%s')
    WHERE taxonID IS NOT NULL;", taxon_pq))

# index the recursive-walk keys: parentNameUsageID (children lookup, each
# generation) and taxonID (seed lookup + the descendant IN-filter).
DBI::dbExecute(con, "CREATE INDEX taxon_parent_idx  ON taxon(parentNameUsageID);")
DBI::dbExecute(con, "CREATE INDEX taxon_taxonid_idx ON taxon(taxonID);")
DBI::dbExecute(con, "CHECKPOINT;")

s <- DBI::dbGetQuery(con, "
  SELECT COUNT(*) AS n_rows, COUNT(DISTINCT taxonRank) AS n_ranks,
         COUNT(*) FILTER (WHERE taxonomicStatus = 'accepted') AS n_accepted
  FROM taxon")
message(sprintf("taxon = %s rows (%s accepted), %s distinct ranks",
                format(s$n_rows, big.mark = ","),
                format(s$n_accepted, big.mark = ","), s$n_ranks))
message("done -> ", out_db)
