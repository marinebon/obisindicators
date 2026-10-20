# Exact point-in-polygon OBIS indicators for one polygon collection, standalone:
# the Mac mini runs this in tmux against the local OBIS snapshot (the monthly refresh calls the same
# function through refresh_obis_h3.sh, OBIS_PLACE_EXACT_COLLECTIONS).
#
# Usage:
#   Rscript data-raw/run_place_exact.R <snapshot glob> <places parquet> <store> <out dir> <coll>
#
#   snapshot glob   OBIS open-data parquet, e.g. /Volumes/msens_big/_big/obis/obis/occurrence/*.parquet
#   places parquet  GeoParquet with place_id and WKB geometry, e.g. ~/data/oceanmetrics/places-internal/mr_eez/places.parquet
#   store           the obis_h3 DuckDB store whose `eov` table gives the EOV membership
#                   ("none" = all-taxa rows only)
#   out dir         a release directory; writes <out dir>/place_exact/coll=<coll>/
#   coll            the collection slug
#
# Env (defaults): OBIS_MEMORY=16GB OBIS_THREADS=6 OBIS_MAX_TEMP=200GB OBIS_TEMP_DIR=<out dir>/.tmp
#   OBIS_GRID_DEG=1  OBIS_ESN=50  OBIS_PKG_ROOT=<this checkout>
#
# Prints the timing and the totals check, and exits 1 when records_in + records_out differs from
# records_total although no places overlap (records are being lost or double counted), 2 on a usage
# error. With overlapping places the check uses records_in_unique and a warning is printed.
#
# Example, on the Mac mini (R with DBI, duckdb, glue, jsonlite; the spatial extension is installed on
# first use), in a tmux window:
#   tmux new-window -n place_exact 'Rscript data-raw/run_place_exact.R \
#     "/Volumes/msens_big/_big/obis/obis/occurrence/*.parquet" \
#     ~/data/oceanmetrics/places-internal/mr_eez/places.parquet \
#     /Volumes/msens_big/_big/obis/obis_h3_global_v20261012.duckdb \
#     /Volumes/msens_big/_big/obis/obis-h3/v20261012 mr_eez \
#     > /tmp/place_exact_mr_eez.log 2>&1; touch /tmp/place_exact_mr_eez.done'

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 5L) {
  message("usage: Rscript data-raw/run_place_exact.R <snapshot glob> <places parquet> <store|none> <out dir> <coll>")
  quit(status = 2L)
}
suppressMessages({library(DBI); library(duckdb); library(glue); library(jsonlite)})

# the R files the function needs (they only define functions), from this checkout
.argv    <- commandArgs(trailingOnly = FALSE)
.file    <- sub("^--file=", "", .argv[grep("^--file=", .argv)])
pkg_root <- Sys.getenv("OBIS_PKG_ROOT", if (length(.file) == 1L) normalizePath(file.path(dirname(.file), "..")) else ".")
Sys.setenv(OBIS_PKG_ROOT = pkg_root)
for (f in c("h3t.R", "store.R", "export.R", "place_exact.R")) source(file.path(pkg_root, "R", f))

snapshot <- path.expand(args[1])
places   <- path.expand(args[2])
store    <- args[3]
out_dir  <- path.expand(args[4])
coll     <- args[5]
stopifnot(length(Sys.glob(snapshot)) > 0, file.exists(places), grepl("^[A-Za-z0-9._-]+$", coll))

# the store's EOV membership, read into R (no h3 extension needed)
eov <- NULL
if (!identical(store, "none")) {
  stopifnot(file.exists(path.expand(store)))
  con_s <- dbConnect(duckdb(), dbdir = path.expand(store), read_only = TRUE)
  eov <- tryCatch(dbGetQuery(con_s, "SELECT eov, taxonID FROM eov"),
                  error = function(e) stop("the store has no `eov` table: ", conditionMessage(e)))
  dbDisconnect(con_s, shutdown = TRUE)
  message("eov membership: ", nrow(eov), " taxa in ", length(unique(eov$eov)), " EOVs")
}

tmp <- Sys.getenv("OBIS_TEMP_DIR", file.path(out_dir, ".tmp"))
t0  <- Sys.time()
message(format(t0, "%Y-%m-%dT%H:%M:%S"), " exact place indicators: ", coll, " from ", snapshot)
res <- obis_place_indicators_exact(
  snapshot, places, eov = eov,
  esn               = as.integer(Sys.getenv("OBIS_ESN", "50")),
  grid_deg          = as.numeric(Sys.getenv("OBIS_GRID_DEG", "1")),
  memory_limit      = Sys.getenv("OBIS_MEMORY", "16GB"),
  threads           = as.integer(Sys.getenv("OBIS_THREADS", "6")),
  temp_dir          = tmp,
  max_temp_dir_size = Sys.getenv("OBIS_MAX_TEMP", "200GB"),
  verbose           = TRUE)
t_calc <- difftime(Sys.time(), t0, units = "mins")

files <- obis_place_exact_write(res, out_dir, coll)
unlink(tmp, recursive = TRUE)

dg <- res$diagnostics
fmt <- function(x) format(x, big.mark = ",", scientific = FALSE)
message(sprintf("done in %.1f min (compute %.1f min)",
                as.numeric(difftime(Sys.time(), t0, units = "mins")), as.numeric(t_calc)))
message("places: ", dg$n_places, " (", dg$n_places_with_records, " with records); pieces: ", fmt(dg$n_pieces),
        "; distinct locations: ", fmt(dg$n_locations))
message("rows: indicators ", fmt(nrow(res$indicators)), ", years ", fmt(nrow(res$years)))
message("records: in ", fmt(dg$records_in), " + out ", fmt(dg$records_out), " = ", fmt(dg$records_in + dg$records_out),
        "; total ", fmt(dg$records_total), "; overlaps ", fmt(dg$overlaps$n), " locations")
message("wrote ", dirname(files[1]))

if (dg$overlaps$n > 0) {
  message("WARN: overlapping places (", paste(utils::head(dg$overlaps$place_ids, 20), collapse = ", "),
          "): in + out exceeds total; unique in ", fmt(dg$records_in_unique), " + out = ",
          fmt(dg$records_in_unique + dg$records_out))
  ok <- dg$records_in_unique + dg$records_out == dg$records_total
  if (!ok) message("ERROR: records_in_unique + records_out != records_total")
  quit(status = if (ok) 0L else 1L)
}
if (dg$records_in + dg$records_out != dg$records_total) {
  message("ERROR: records_in + records_out != records_total (", fmt(dg$records_in + dg$records_out),
          " vs ", fmt(dg$records_total), ")")
  quit(status = 1L)
}
message("totals check ok")
