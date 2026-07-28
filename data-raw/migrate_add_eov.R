#!/usr/bin/env Rscript
# One-off migration: add the Essential Ocean Variable layers (`eov` membership +
# precomputed `idx_h3_eov` indicators) to an EXISTING obis_h3 DuckDB store, so
# the h3t service can serve an EOV map from a small clustered lookup instead of
# re-aggregating occ_h3 on every tile. See obis_eov_bake() and obis_eov_sql().
#
# EOVs are defined taxonomically by the IOOS Marine Life Data Network as a short
# list of root AphiaIDs per variable (fish, hardCorals, mangroves, marineMammals,
# seabirds, seagrasses, seaTurtles):
#   https://github.com/ioos/marine_life_data_network/tree/main/eov_taxonomy
#
# Requires the `taxon` table (migrate_add_taxon.R). Run migrate_fill_taxon_gaps.R
# FIRST if you have not: any EOV member whose AphiaID is missing from `taxon` is
# silently excluded, which on the un-filled 2026-07 global store meant ~7% of
# distinct aphiaids were invisible to every EOV query.
#
# Writes a NEW file so the live read-only store is untouched until you swap the
# symlink, e.g.:
#   ln -sf /share/data/obis/obis_h3_global_eov_vYYYYMMDD.duckdb \
#          /share/data/obis/obis_h3.duckdb
#   docker compose -f .../server/docker-compose.yml restart h3t
#   docker compose -f .../server/docker-compose.yml exec h3tcache \
#     varnishadm 'ban req.url ~ "^/h3t/"'
#
# Usage:
#   Rscript migrate_add_eov.R <in.duckdb> <out.duckdb> [eov ...]
# Env (optional caps): DUCKDB_MEMORY_LIMIT (8GB), DUCKDB_THREADS (4),
#   DUCKDB_TEMP_DIR (<dir(out)>/duckdb_tmp).

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2)
  stop("usage: migrate_add_eov.R <in.duckdb> <out.duckdb> [eov ...]")
in_db  <- args[1]
out_db <- args[2]
eovs   <- if (length(args) > 2) args[-(1:2)] else NULL

stopifnot(file.exists(in_db))
if (file.exists(out_db)) stop("out.duckdb already exists: ", out_db)
stopifnot(requireNamespace("DBI",    quietly = TRUE),
          requireNamespace("duckdb", quietly = TRUE))

# locate the package root and source only what the bake needs (DBI/duckdb/glue);
# a full package load also pulls in gsl + the h3 R package
.argv    <- commandArgs(trailingOnly = FALSE)
.file    <- sub("^--file=", "", .argv[grep("^--file=", .argv)])
pkg_root <- if (length(.file) == 1) {
  normalizePath(file.path(dirname(.file), ".."))
} else {
  Sys.getenv("OBIS_PKG_ROOT", "/share/github/marinebon/obisindicators")
}
library(glue)
source(file.path(pkg_root, "R", "h3t.R"))
source(file.path(pkg_root, "R", "taxon.R"))
source(file.path(pkg_root, "R", "taxon_gapfill.R"))  # obis_taxon_orphans()
source(file.path(pkg_root, "R", "eov.R"))

message("copying ", in_db, " -> ", out_db, " ...")
if (!file.copy(in_db, out_db)) stop("copy failed (disk space?): ", out_db)

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

if (!"taxon" %in% DBI::dbListTables(con))
  stop("no `taxon` table in ", in_db, " — run migrate_add_taxon.R first")

# report the reachability gap: EOV membership can only be as complete as `taxon`
orphans <- obis_taxon_orphans(con)
if (nrow(orphans))
  warning(nrow(orphans), " aphiaid(s) in occ_h3 are missing from `taxon` (",
          format(sum(as.numeric(orphans$records)), big.mark = ","),
          " records) and will be excluded from every EOV — run ",
          "migrate_fill_taxon_gaps.R first", call. = FALSE)

s <- obis_eov_bake(con, eov = eovs)

DBI::dbExecute(con, "CHECKPOINT;")
message("done: ", out_db)
print(s, row.names = FALSE)
