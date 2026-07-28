#!/usr/bin/env Rscript
# One-off migration: close the reachability gap in an EXISTING obis_h3 DuckDB
# store's `taxon` table by looking up, via the WoRMS REST API, every AphiaID
# that occ_h3 carries but taxon.txt lacked — then every ancestor those rows
# reference, until the tree is closed. See obis_taxon_fill_gaps().
#
# Why: the bulk WoRMS DwC download (build_taxon_parquet.R) is not a complete
# cover of the AphiaIDs OBIS uses (notably algae, whose WoRMS records come from
# separate thematic databases). On the 2026-07 global store ~7% of distinct
# aphiaids (~6.8% of records) were unreachable, so they silently vanished from
# every aphiaid / EOV / SPUE query. Run this AFTER migrate_add_taxon.R.
#
# Writes a NEW file so the live read-only store is untouched until you swap the
# symlink, e.g.:
#   ln -sf /share/data/obis/obis_h3_global_gapfill_vYYYYMMDD.duckdb \
#          /share/data/obis/obis_h3.duckdb
#   docker compose -f .../server/docker-compose.yml restart h3t
#   docker compose -f .../server/docker-compose.yml exec h3tcache \
#     varnishadm 'ban req.url ~ "^/h3t/"'
#
# Usage:
#   Rscript migrate_fill_taxon_gaps.R <in.duckdb> <out.duckdb> [min_records]
# Env (optional): DUCKDB_MEMORY_LIMIT (8GB), DUCKDB_THREADS (4),
#   DUCKDB_TEMP_DIR (<dir(out)>/duckdb_tmp), WORMS_CONCURRENCY (4),
#   OBIS_GAPFILL_REPORT (csv path for the unresolved-id report).

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2)
  stop("usage: migrate_fill_taxon_gaps.R <in.duckdb> <out.duckdb> [min_records]")
in_db  <- args[1]
out_db <- args[2]
min_recs <- if (length(args) >= 3) as.integer(args[3]) else 0L

stopifnot(file.exists(in_db))
if (file.exists(out_db)) stop("out.duckdb already exists: ", out_db)
stopifnot(requireNamespace("DBI",   quietly = TRUE),
          requireNamespace("duckdb", quietly = TRUE),
          requireNamespace("httr2", quietly = TRUE))

# locate the package root and source only R/taxon.R + R/taxon_gapfill.R — the
# gap-fill needs DBI/duckdb/glue/httr2 only; a full package load also pulls in
# gsl + the h3 R package, which the server build does not have.
.argv    <- commandArgs(trailingOnly = FALSE)
.file    <- sub("^--file=", "", .argv[grep("^--file=", .argv)])
pkg_root <- if (length(.file) == 1) {
  normalizePath(file.path(dirname(.file), ".."))
} else {
  Sys.getenv("OBIS_PKG_ROOT", "/share/github/marinebon/obisindicators")
}
library(glue)
source(file.path(pkg_root, "R", "taxon.R"))
source(file.path(pkg_root, "R", "taxon_gapfill.R"))

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

# before/after reachability, so the migration reports what it actually bought
before <- obis_taxon_orphans(con)
message("before: ", nrow(before), " orphan aphiaid(s), ",
        format(sum(as.numeric(before$records)), big.mark = ","), " records unreachable")

conc <- as.integer(Sys.getenv("WORMS_CONCURRENCY", "4"))
res  <- obis_taxon_fill_gaps(
  con,
  fetch = function(ids) wm_aphia_records(ids, concurrency = conc, verbose = TRUE),
  min_records = min_recs)

after <- obis_taxon_orphans(con)
message("after:  ", nrow(after), " orphan aphiaid(s), ",
        format(sum(as.numeric(after$records)), big.mark = ","), " records unreachable")

# the ids WoRMS itself could not resolve are a real data-quality signal (deleted
# or quarantined Aphia records, or non-WoRMS ids in OBIS) — write them out
# rather than leaving them buried in the log
report <- Sys.getenv("OBIS_GAPFILL_REPORT",
                     file.path(dirname(out_db), "taxon_gapfill_unresolved.csv"))
if (nrow(after)) {
  utils::write.csv(after, report, row.names = FALSE)
  message("unresolved ids written to ", report)
}

DBI::dbExecute(con, "CHECKPOINT;")
message("done: ", out_db,
        " (added ", nrow(res$added), " taxon rows in ", res$rounds, " round(s))")
