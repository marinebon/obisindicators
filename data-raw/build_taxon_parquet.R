#!/usr/bin/env Rscript
# Extract the WoRMS taxonomy subset needed to resolve arbitrary-rank children
# (see obis_taxon_children()) from a WoRMS DarwinCore `taxon.txt` download into
# a compact `taxon.parquet`. Kept separate from migrate_add_taxon.R so the
# heavy 1.3 GB CSV read runs wherever the WoRMS download lives (typically a
# laptop), and only the small parquet is shipped to the server for the bake.
#
# WoRMS ids are LSID-prefixed (urn:lsid:marinespecies.org:taxname:<AphiaID>);
# stripped to integer AphiaIDs here so `taxonID` matches OBIS `occ_h3.aphiaid`.
#
# Usage:
#   Rscript build_taxon_parquet.R [taxon.txt] [taxon.parquet]
# Env (used as defaults): OBIS_WORMS_TAXON, OBIS_TAXON_PARQUET.
#
# see also: data-raw/migrate_add_taxon.R (bakes the parquet into obis_h3.duckdb)
# and MarineSensitivity/workflows/ingest_taxon.qmd (the fuller WoRMS ingest).

librarian::shelf(DBI, duckdb, glue, quiet = TRUE)

is_server <- Sys.info()[["sysname"]] == "Linux"
dir_data  <- ifelse(is_server, "/share/data", "~/My Drive/projects/msens/data")
dir_worms <- file.path(
  dir_data, "raw/marinespecies.org/checklistbank.org_dataset-2011_v2026-07-02")

# arg > env var > default
args      <- commandArgs(trailingOnly = TRUE)
or_else   <- function(x, default) if (!is.null(x) && !is.na(x) && nzchar(x)) x else default
taxon_txt <- or_else(args[1], Sys.getenv("OBIS_WORMS_TAXON",   file.path(dir_worms, "taxon.txt")))
taxon_pq  <- or_else(args[2], Sys.getenv("OBIS_TAXON_PARQUET", file.path(dir_data, "derived", "taxon.parquet")))
taxon_txt <- path.expand(taxon_txt)
taxon_pq  <- path.expand(taxon_pq)

stopifnot(file.exists(taxon_txt))
dir.create(dirname(taxon_pq), showWarnings = FALSE, recursive = TRUE)

con <- DBI::dbConnect(duckdb::duckdb())
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

# read all-varchar (avoid type sniffing on a 1.3 GB DwC file), strip the LSID
# prefix, TRY_CAST ids to BIGINT (non-numeric -> NULL). keep only the columns
# the recursive children walk needs, plus taxonomicStatus for optional filtering.
lsid <- "urn:lsid:marinespecies.org:taxname:"
message("reading ", taxon_txt, " ...")
DBI::dbExecute(con, glue::glue("
  COPY (
    SELECT
      TRY_CAST(replace(taxonID,             '{lsid}', '') AS BIGINT) AS taxonID,
      TRY_CAST(replace(parentNameUsageID,   '{lsid}', '') AS BIGINT) AS parentNameUsageID,
      TRY_CAST(replace(acceptedNameUsageID, '{lsid}', '') AS BIGINT) AS acceptedNameUsageID,
      scientificName,
      taxonRank,
      taxonomicStatus
    FROM read_csv(
      '{taxon_txt}', delim = '\t', header = true, all_varchar = true,
      quote = '\"', escape = '\"', nullstr = '')
    WHERE taxonID IS NOT NULL
  ) TO '{taxon_pq}' (FORMAT PARQUET);"))

s <- DBI::dbGetQuery(con, glue::glue("
  SELECT COUNT(*) AS n_rows,
         COUNT(parentNameUsageID) AS n_with_parent,
         COUNT(DISTINCT taxonRank) AS n_ranks
  FROM read_parquet('{taxon_pq}')"))
message(sprintf(
  "wrote %s: %s rows (%s with parent), %s distinct ranks",
  taxon_pq, format(s$n_rows, big.mark = ","),
  format(s$n_with_parent, big.mark = ","), s$n_ranks))
