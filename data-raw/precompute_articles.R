#!/usr/bin/env Rscript
# knit vignettes/articles/*.Rmd.orig -> *.Rmd against a LOCAL obis_h3 store, so
# pkgdown on GitHub Actions (which has no store) renders the committed .Rmd with
# every figure and table already in place. the .Rmd.orig files are the SOURCE:
# edit those, re-run this, and commit both the .Rmd and vignettes/articles/figures/.
#
#   export OBIS_H3_DUCKDB=~/_big/obis_h3_demo_gulf_filled.duckdb   # or the global store
#   export OBIS_H3_DUCKDB_BEFORE=~/_big/obis_h3_demo_gulf.duckdb   # eov: before/after gap-fill (optional)
#   export SDM_TIF=~/_big/msens/derived/v8/marine-atlas/native/am/am_ITS-Mam-180530.tif  # humpback, GRADED
#                                                                   # taxon_children: SPUE vs SDM (optional)
#   export PLACES_GPKG=/path/to/places.gpkg                         # places: else onmsR sanctuaries (optional)
#   Rscript data-raw/precompute_articles.R                          # all articles
#   Rscript data-raw/precompute_articles.R scaling eov              # a subset
#
# side effect: each article also saves its manuscript figures + csv to
# paper/figures/ via paper/_common.R (see paper/README.md).

args    <- commandArgs(trailingOnly = TRUE)
dir_art <- "vignettes/articles"
stopifnot("run from the package root" = dir.exists(dir_art))

origs <- list.files(dir_art, pattern = "\\.Rmd\\.orig$")
nms   <- sub("\\.Rmd\\.orig$", "", origs)
if (length(args)) {
  unknown <- setdiff(args, nms)
  if (length(unknown)) stop("no such article(s): ", paste(unknown, collapse = ", "),
                            "; have: ", paste(nms, collapse = ", "))
  keep  <- nms %in% args
  origs <- origs[keep]; nms <- nms[keep]
}

store <- Sys.getenv("OBIS_H3_DUCKDB")
if (!nzchar(store) || !file.exists(path.expand(store)))
  stop("set OBIS_H3_DUCKDB to an obis_h3 store (build one with paper/build_demo_store.R)")

# prefer the dev checkout so edits show up without reinstalling
if (requireNamespace("pkgload", quietly = TRUE)) pkgload::load_all(".", quiet = TRUE)

old <- setwd(dir_art); on.exit(setwd(old), add = TRUE)
for (i in seq_along(origs)) {
  t0 <- Sys.time()
  message("knitting ", origs[i], " -> ", nms[i], ".Rmd  (store: ", basename(store), ")")
  knitr::knit(origs[i], paste0(nms[i], ".Rmd"),
              envir = new.env(parent = globalenv()), quiet = TRUE)
  message("  done in ", round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1), " min")
}
