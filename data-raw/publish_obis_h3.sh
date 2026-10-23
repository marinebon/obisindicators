#!/usr/bin/env bash
# Publish an exported obis-h3 release to the Ocean Metrics public bucket through oceanmetrics/platform
# scripts/om-publish.sh, the one publisher of the bucket: both stores (R2 oceanmetrics-io-public-enam, which
# storage.oceanmetrics.io serves, then S3 oceanmetrics.io-public), content types by extension, never a delete.
# Runs on the host (the Mac mini), after data-raw/run_refresh_docker.sh's container staged the release with
# OBIS_UPLOAD=host, so the R2 keys (~/.config/oceanmetrics/r2.env, through the rclone wrapper) never enter the image.
#
# Usage:
#   data-raw/publish_obis_h3.sh [--dry-run] <release dir> <release tag> <latest.json> <collection.json>
#
# Steps, in the order readers need them (refresh_obis_h3.sh's f, g, g2):
#   f   the release folder -> obis-h3/<tag>/ (additive), then a count check on each store: fewer files there than
#       in the folder stops before the pointers
#   g   latest.json -> obis-h3/latest.json        (Cache-Control max-age=300; the R2 copy it replaces kept under
#   g2  collection.json -> obis-h3/collection.json  obis-h3/_history/<date>/, R2 having no object versions)
# --dry-run: om-publish's dry run (read-only listings of both stores) for each file that exists; nothing is written.
#
# Env: OM_PUBLISH (the script; default a platform checkout at ~/Github/oceanmetrics/platform), OM_STORE (both, r2,
#   s3), OM_S3_BUCKET, OM_R2_BUCKET, OM_RCLONE (as om-publish reads them), S3_PREFIX=obis-h3.
# Exit: 0 ok, 1 a step failed, 2 usage.
set -euo pipefail

DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ $# -eq 4 ] || { sed -n '8,9p' "$0" >&2; exit 2; }
DIR="$1"; RELEASE="$2"; LATEST="$3"; STABLE="$4"
[[ "$RELEASE" =~ ^v[0-9]{8}$ ]] || { echo "ERROR: release tag must look like v20260828, got '$RELEASE'" >&2; exit 2; }
PREFIX="${S3_PREFIX:-obis-h3}"
P="${OM_PUBLISH:-$HOME/Github/oceanmetrics/platform/scripts/om-publish.sh}"
[ -x "$P" ] || { echo "ERROR: om-publish.sh not found at $P (set OM_PUBLISH)" >&2; exit 1; }
REALLY=--really; [ "$DRY" -eq 1 ] && REALLY=--dry-run
STORE="${OM_STORE:-both}"
S3_BUCKET="${OM_S3_BUCKET:-oceanmetrics.io-public}"
R2_BUCKET="${OM_R2_BUCKET:-oceanmetrics-io-public-enam}"
RCLONE="${OM_RCLONE:-$HOME/.config/oceanmetrics/rclone-r2.sh}"
say() { echo "=== $(date -u +%H:%M:%SZ) $* ==="; }

# ---- (f) the release folder -------------------------------------------------------------------
if [ -d "$DIR" ]; then
  say "f. $DIR -> $PREFIX/$RELEASE/ (om-publish $REALLY, no delete)"
  "$P" $REALLY "$DIR" "$PREFIX/$RELEASE"
elif [ "$DRY" -eq 1 ]; then
  echo "(dry run) no $DIR yet: om-publish $REALLY $DIR $PREFIX/$RELEASE"
else
  echo "ERROR: no release folder $DIR" >&2; exit 1
fi
if [ "$DRY" -eq 0 ]; then
  n_local=$(find "$DIR" -type f ! -name .DS_Store | wc -l | tr -d ' ')
  if [ "$STORE" != r2 ]; then
    n=$(aws s3 ls "s3://$S3_BUCKET/$PREFIX/$RELEASE/" --recursive | wc -l | tr -d ' ')
    echo "files: local $n_local, on S3 $n"
    [ "$n" -ge "$n_local" ] || { echo "ERROR: S3 holds fewer files ($n) than the export ($n_local): latest.json NOT written" >&2; exit 1; }
  fi
  if [ "$STORE" != s3 ]; then
    n=$("$RCLONE" lsf -R --files-only --fast-list "r2:$R2_BUCKET/$PREFIX/$RELEASE" | wc -l | tr -d ' ')
    echo "files: local $n_local, on R2 $n"
    [ "$n" -ge "$n_local" ] || { echo "ERROR: R2 holds fewer files ($n) than the export ($n_local): latest.json NOT written" >&2; exit 1; }
  fi
fi

# ---- (g) latest.json, then (g2) the stable collection.json -----------------------------------------
pointer() {   # pointer <step> <file> <published name>
  if [ -f "$2" ]; then
    say "$1. $2 -> $PREFIX/$3"
    "$P" $REALLY --keep-history --cache-control max-age=300 "$2" "$PREFIX" --as "$3"
  elif [ "$DRY" -eq 1 ]; then
    echo "(dry run) no $2 yet: om-publish $REALLY --keep-history --cache-control max-age=300 $2 $PREFIX --as $3"
  else
    echo "ERROR: no $2" >&2; exit 1
  fi
}
pointer g "$LATEST" latest.json
pointer g2 "$STABLE" collection.json
say "published $RELEASE$([ "$DRY" -eq 1 ] && echo ' (dry run)')"
