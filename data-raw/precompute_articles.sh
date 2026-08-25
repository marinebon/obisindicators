#!/usr/bin/env bash
# Precompute the store articles against the GLOBAL store on the MST server.
#
# Runs data-raw/precompute_articles.R inside the `rstudio` container (which
# carries the package's dependencies; see MarineSensitivity/server/rstudio/
# Dockerfile) as uid 1000 = host `ubuntu`, so the knitted .Rmd and figures land
# in this checkout owned by the same user that owns it. Run on the HOST:
#
#   cd /share/github/marinebon/obisindicators && git pull
#   data-raw/precompute_articles.sh                 # all articles, in the background
#   data-raw/precompute_articles.sh decadal places  # a subset
#   tail -f /share/data/obis_eov_work/precompute_articles.log
#
# then commit vignettes/articles/ + paper/figures/ (or rsync them to a laptop
# and commit there). Each article states which store it was rendered against.
#
# Env (override to point elsewhere):
#   OBIS_H3_DUCKDB         the store; default = the deployed symlink, RESOLVED so the
#                          article label carries the versioned file name
#   OBIS_H3_DUCKDB_BEFORE  pre-gap-fill store for the eov before/after comparison
#   SDM_TIF                humpback whale merged SDM raster for taxon_children (Fig. 4)
#   PLACES_GPKG            polygons for places (default: onmsR::sanctuaries)
set -euo pipefail

PKG_ROOT="${PKG_ROOT:-/share/github/marinebon/obisindicators}"
LOG_DIR="${LOG_DIR:-/share/data/obis_eov_work}"
STORE="${OBIS_H3_DUCKDB:-$(readlink -f /share/data/obis/obis_h3.duckdb)}"
BEFORE="${OBIS_H3_DUCKDB_BEFORE:-/share/data/obis/obis_h3_global_hp_v20260717.duckdb}"
SDM="${SDM_TIF:-/share/data/derived/v8/marine-atlas/native/merged/ms_merge_WORMS_137092.tif}"
PLACES="${PLACES_GPKG:-}"

command -v docker >/dev/null || { echo "docker not on PATH — run on the HOST" >&2; exit 1; }
docker inspect -f '{{.State.Running}}' rstudio 2>/dev/null | grep -q true || { echo "rstudio container not running" >&2; exit 1; }
for f in "$STORE" "$BEFORE" "$SDM"; do
  [ -f "$f" ] || echo "note: missing $f (the article that needs it will say so)" >&2
done
mkdir -p "$LOG_DIR"
log="$LOG_DIR/precompute_articles.log"

echo "store: $STORE"
echo "log:   $log"
nohup docker exec -u 1000:1000 -w "$PKG_ROOT" \
  -e HOME=/home/rstudio \
  -e OBIS_H3_DUCKDB="$STORE" \
  -e OBIS_H3_DUCKDB_BEFORE="$BEFORE" \
  -e SDM_TIF="$SDM" \
  -e PLACES_GPKG="$PLACES" \
  rstudio Rscript data-raw/precompute_articles.R "$@" > "$log" 2>&1 &
echo "started pid $! — tail -f $log"
