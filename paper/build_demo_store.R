#!/usr/bin/env Rscript
# build a REGIONAL demo obis_h3 store for developing the paper's figures without
# the global store on the MST server. Needs:
#   - a local OBIS export loaded in DuckDB with the DwC columns
#     (default ~/_big/obis.duckdb, table `occ`, the 2025-03-18 export), and
#   - a WoRMS taxon table (default ~/_big/msens/derived/spp.duckdb, table `worms`).
# Steps: bbox subset -> flat parquet -> build_obis_h3_duckdb() -> bake `taxon`
# -> (optionally) gap-fill from WoRMS REST -> bake EOV layers.
#
# usage:
#   Rscript paper/build_demo_store.R [out.duckdb] [--bbox=-98,8,-60,31] [--fill]
#   then:  export OBIS_H3_DUCKDB=~/_big/obis_h3_demo_gulf.duckdb
#
# the default bbox (Gulf of Mexico + Caribbean) holds ~8.3M species-level
# records and all seven EOVs incl. seagrasses and mangroves.

args <- commandArgs(trailingOnly = TRUE)
arg  <- function(flag, default) {
  hit <- grep(paste0("^", flag, "="), args, value = TRUE)
  if (length(hit)) sub(paste0("^", flag, "="), "", hit[1]) else default
}
out_duckdb <- if (length(args) && !grepl("^--", args[1])) args[1] else
  path.expand("~/_big/obis_h3_demo_gulf.duckdb")
bbox  <- as.numeric(strsplit(arg("--bbox", "-98,8,-60,31"), ",")[[1]])
fill  <- "--fill" %in% args
src_duckdb   <- path.expand(Sys.getenv("OBIS_SRC_DUCKDB",  "~/_big/obis.duckdb"))
worms_duckdb <- path.expand(Sys.getenv("WORMS_DUCKDB",     "~/_big/msens/derived/spp.duckdb"))
parquet      <- sub("\\.duckdb$", "_src.parquet", out_duckdb)

suppressMessages({
  library(DBI); library(duckdb)
  if (requireNamespace("pkgload", quietly = TRUE) && file.exists("DESCRIPTION"))
    pkgload::load_all(".", quiet = TRUE) else library(obisindicators)
})
stopifnot(file.exists(src_duckdb), file.exists(worms_duckdb))
t0 <- Sys.time()

# 1. bbox subset of the OBIS export as a flat parquet the builder reads ----
message("1/5 exporting bbox ", paste(bbox, collapse = ","), " from ", src_duckdb)
con <- dbConnect(duckdb(), dbdir = src_duckdb, read_only = TRUE)
dbExecute(con, sprintf("
  COPY (
    SELECT decimalLongitude, decimalLatitude, aphiaid, phylum, class, \"order\",
           family, genus, species, date_year, dropped, absence
    FROM occ
    WHERE species IS NOT NULL
      AND decimalLongitude BETWEEN %s AND %s
      AND decimalLatitude  BETWEEN %s AND %s
  ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD);",
  bbox[1], bbox[3], bbox[2], bbox[4], parquet))
dbDisconnect(con, shutdown = TRUE)
message("   ", parquet, " (", round(file.size(parquet) / 1e6), " MB)")

# 2. the store: occ_h3 (tiers 3/5/7) + idx_h3 (res 1-7) + idx_h3_taxon ----
message("2/5 build_obis_h3_duckdb() -> ", out_duckdb)
build_obis_h3_duckdb(
  parquet, out_duckdb,
  memory_limit = "6GB", threads = 4L,
  temp_dir = file.path(dirname(out_duckdb), "duckdb_tmp"), max_temp_dir_size = "20GB")

# 3. bake the WoRMS taxon table (same DDL as data-raw/migrate_add_taxon.R) ----
message("3/5 baking taxon from ", worms_duckdb)
con <- dbConnect(duckdb(), dbdir = out_duckdb, read_only = FALSE)
dbExecute(con, "LOAD h3;")
dbExecute(con, sprintf("ATTACH '%s' AS spp (READ_ONLY);", worms_duckdb))
dbExecute(con, "
  CREATE TABLE taxon AS
  SELECT CAST(taxonID AS BIGINT) AS taxonID,
         CAST(parentNameUsageID AS BIGINT) AS parentNameUsageID,
         CAST(acceptedNameUsageID AS BIGINT) AS acceptedNameUsageID,
         scientificName, taxonRank, taxonomicStatus
  FROM spp.worms;")
dbExecute(con, "CREATE INDEX taxon_parent_idx  ON taxon(parentNameUsageID);")
dbExecute(con, "CREATE INDEX taxon_taxonid_idx ON taxon(taxonID);")
dbExecute(con, "DETACH spp;")

# 4. report (and optionally close) the taxonomy coverage gap ----
orph <- obis_taxon_orphans(con)
message("4/5 orphan AphiaIDs (in occ_h3, absent from taxon): ",
        format(nrow(orph), big.mark = ","), " covering ",
        format(sum(orph$records), big.mark = ","), " records")
if (fill) {
  message("   filling from WoRMS REST (network) ...")
  print(obis_taxon_fill_gaps(con))
} else {
  message("   (pass --fill to close it from the WoRMS REST API; ~minutes)")
}

# 5. EOV membership + precomputed idx_h3_eov ----
message("5/5 obis_eov_bake()")
obis_eov_bake(con)
dbExecute(con, "CHECKPOINT;")
dbDisconnect(con, shutdown = TRUE)

message("done in ", round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1),
        " min: ", out_duckdb, " (", round(file.size(out_duckdb) / 1e9, 2), " GB)\n",
        "export OBIS_H3_DUCKDB=", out_duckdb)
