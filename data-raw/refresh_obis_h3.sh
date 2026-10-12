#!/usr/bin/env bash
# Monthly refresh of the obis-h3 release that the obis-hex app reads:
#   sync OBIS open data -> build the H3 store -> export hive-partitioned Parquet
#   -> validate -> upload to S3 -> publish latest.json.
# Runs either on a Linux host that has the `plumber` container (msens: R through
# `docker exec plumber`), or inside the obis-h3 image (data-raw/docker/Dockerfile) with
# BUILD_CONTAINER="" so R runs directly; data-raw/run_refresh_docker.sh does the latter on the
# Mac mini. Needs aws, flock, python3 (and docker in the first mode). Scheduled by
# oceanmetrics/erddap-places .github/workflows/obis-h3.yml; also fine to run by hand.
#
# Usage:
#   data-raw/refresh_obis_h3.sh [--skip-sync] [--skip-build] [--skip-export]
#                               [--skip-upload] [--release vYYYYMMDD] [--dry-run]
#
#   --skip-sync    use the snapshot already on disk (release tag then comes from
#                  --release or from the marker written by the last sync)
#   --skip-build   reuse the newest obis_h3_global_*.duckdb (or $STORE)
#   --skip-export  reuse an existing $DIR_OUT/<release>/ (it is still validated)
#   --skip-upload  stop after validation; also skips latest.json
#   --skip-taxonomy  keep $TAXON_PARQUET as it is (no ChecklistBank check)
#   --taxonomy-only  run only (a2), then stop (refresh taxon.parquet by hand)
#   --release TAG  release tag, vYYYYMMDD (default: the UTC date of the sync)
#   --dry-run      print what each step would run; change nothing
#
# Steps: (a) preflight disk (exit 2 if < MIN_FREE_GB) (a2) WoRMS taxonomy: rebuild
# $TAXON_PARQUET from ChecklistBank's WoRMS archive when its version changed (b) sync
# (c) build (taxon gap-fill from the WoRMS REST API included) (d) export obis_h3_export_parquet() (e) validate vs the
# previous release (exit 4) (f) aws s3 sync, no --delete (g) latest.json LAST
# (h) summary.
#
# Exit codes: 0 ok, 1 step failed, 2 not enough disk, 3 another run holds the lock,
#             4 validation failed (nothing was uploaded).
#
# NOT done here: swapping the h3t service to the new store (needs sudo). After a
# successful run, on the host:
#   data-raw/deploy_obis_h3.sh --skip-sync --skip-build --store <new .duckdb> --yes
# The WoRMS taxon.parquet ($TAXON_PARQUET) comes from ChecklistBank dataset 2011 (WoRMS's own
# monthly DwC-A, re-imported there; public, no login): step (a2) compares the dataset's `version`
# with $TAXON_PARQUET.json and, when it differs, downloads /archive (~350 MB, kept in $WORMS_DIR),
# runs data-raw/build_taxon_parquet.R and records the version. If ChecklistBank cannot be reached
# the existing parquet is kept (a warning); with none at all the run stops. AphiaIDs that OBIS
# carries but the download lacks (AlgaeBase-sourced algae, ...) are fetched from the WoRMS REST
# API by the build itself (obis_taxon_fill_gaps(), to closure; the build stops if any remain).
#
# NEVER set OBIS_GLOBAL=true: streaming from S3 OOM-wedged msens on 2026-06-23. This
# script always builds from the local parquet snapshot, with the build script's
# guards (memory, threads, spill cap) passed explicitly.
#
# Env (defaults): OBIS_DIR=/share/data/obis  OCC_DIR=$OBIS_DIR/occurrence
#   DIR_OUT=/share/data/obis-h3  LOG_DIR=$OBIS_DIR/log  PKG_ROOT=/share/github/marinebon/obisindicators
#   BUILD_CONTAINER=plumber ("" = run R here, inside the obis-h3 image)  MIN_FREE_GB=110  MIN_PCT=90 (new vs previous total records)
#   OBIS_MEMORY=7GB OBIS_THREADS=2 OBIS_MAX_TEMP=20GB OBIS_TEMP_DIR=$OBIS_DIR/tmp (build)
#   EXPORT_MEMORY=6GB EXPORT_THREADS=2 (export)  STORE=<.duckdb> (with --skip-build)
#   WORMS_DIR=$(dirname $TAXON_PARQUET)/worms  CLB_DATASET=2011 (ChecklistBank key of WoRMS)
#   S3_BUCKET=oceanmetrics.io-public  S3_PREFIX=obis-h3
#   PUBLIC_BASE=https://s3.us-east-1.amazonaws.com/oceanmetrics.io-public/obis-h3
#   PREV_RELEASE=<tag to compare with>  ALLOW_NO_PREV=1 (skip the comparison if none can be read)
#   EXPORT_OVERWRITE=1 (replace a COMPLETE existing $DIR_OUT/<release>)

set -euo pipefail

OBIS_DIR="${OBIS_DIR:-/share/data/obis}"
OCC_DIR="${OCC_DIR:-$OBIS_DIR/occurrence}"
DIR_OUT="${DIR_OUT:-/share/data/obis-h3}"
LOG_DIR="${LOG_DIR:-$OBIS_DIR/log}"
PKG_ROOT="${PKG_ROOT:-/share/github/marinebon/obisindicators}"
BUILD_CONTAINER="${BUILD_CONTAINER-plumber}"   # set but empty: R runs here (inside the obis-h3 image)
MIN_FREE_GB="${MIN_FREE_GB:-110}"
MIN_PCT="${MIN_PCT:-90}"
OBIS_MEMORY="${OBIS_MEMORY:-7GB}"
OBIS_THREADS="${OBIS_THREADS:-2}"
OBIS_MAX_TEMP="${OBIS_MAX_TEMP:-20GB}"
OBIS_TEMP_DIR="${OBIS_TEMP_DIR:-$OBIS_DIR/tmp}"
EXPORT_MEMORY="${EXPORT_MEMORY:-6GB}"
EXPORT_THREADS="${EXPORT_THREADS:-2}"
TAXON_PARQUET="${TAXON_PARQUET:-$(dirname "$OBIS_DIR")/derived/taxon.parquet}"
WORMS_DIR="${WORMS_DIR:-$(dirname "$TAXON_PARQUET")/worms}"
CLB_DATASET="${CLB_DATASET:-2011}"
CLB_API="https://api.checklistbank.org/dataset/$CLB_DATASET"
S3_BUCKET="${S3_BUCKET:-oceanmetrics.io-public}"
S3_PREFIX="${S3_PREFIX:-obis-h3}"
PUBLIC_BASE="${PUBLIC_BASE:-https://s3.us-east-1.amazonaws.com/$S3_BUCKET/$S3_PREFIX}"
LOCK_FILE="${LOCK_FILE:-$OBIS_DIR/refresh_obis_h3.lock}"
SYNC_MARKER="$OBIS_DIR/occurrence.synced_at"

SKIP_SYNC=0; SKIP_BUILD=0; SKIP_EXPORT=0; SKIP_UPLOAD=0; SKIP_TAXONOMY=0; TAXONOMY_ONLY=0; DRY=0; RELEASE=""
WORMS_VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-sync)   SKIP_SYNC=1 ;;
    --skip-build)  SKIP_BUILD=1 ;;
    --skip-export) SKIP_EXPORT=1 ;;
    --skip-upload) SKIP_UPLOAD=1 ;;
    --skip-taxonomy) SKIP_TAXONOMY=1 ;;
    --taxonomy-only) TAXONOMY_ONLY=1; SKIP_SYNC=1; SKIP_EXPORT=1; SKIP_UPLOAD=1 ;;
    --dry-run)     DRY=1 ;;
    --release)     RELEASE="${2:?--release needs vYYYYMMDD}"; shift ;;
    -h|--help)     sed -n '2,47p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

die()  { echo "ERROR: $1" >&2; exit "${2:-1}"; }
step() { echo; echo "=== $(date -u +%H:%M:%SZ) $* ==="; }
# run a command, or only print it with --dry-run
run()  { if [ "$DRY" -eq 1 ]; then echo "+ (dry-run) $*"; else "$@"; fi; }

# ---- lock + log ---------------------------------------------------------------
if [ "$DRY" -eq 0 ]; then
  mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
  exec 9>"$LOCK_FILE" || die "cannot open lock file $LOCK_FILE (is $OBIS_DIR writable by $(id -un)?)"
  flock -n 9 || die "another refresh holds $LOCK_FILE" 3

  if ! mkdir -p "$LOG_DIR" 2>/dev/null || [ ! -w "$LOG_DIR" ]; then
    fallback="${XDG_STATE_HOME:-$HOME/.local/state}/obis-h3/log"
    echo "WARN: $LOG_DIR not writable; logging to $fallback" >&2
    LOG_DIR="$fallback"; mkdir -p "$LOG_DIR"
  fi
  LOG="$LOG_DIR/refresh_$(date -u +%Y%m%d).log"
  exec > >(tee -a "$LOG") 2>&1
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "log=$LOG" >> "$GITHUB_OUTPUT"
  echo "log: $LOG"
fi
echo "refresh_obis_h3.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(hostname) as $(id -un)$([ "$DRY" -eq 1 ] && echo " (DRY RUN)")"
if [ -n "$BUILD_CONTAINER" ]; then echo "R runs in container $BUILD_CONTAINER (docker exec)"; else echo "R runs here (BUILD_CONTAINER empty)"; fi

# ---- helpers --------------------------------------------------------------------
# run a command where R lives: `docker exec` into $BUILD_CONTAINER, or here when it is empty (inside
# the obis-h3 image); leading VAR=value words become the command's environment
in_r() {
  local envs=() e=()
  while [ $# -gt 0 ] && [[ "$1" =~ ^[A-Z_][A-Z0-9_]*= ]]; do envs+=("$1"); shift; done
  if [ -n "$BUILD_CONTAINER" ]; then
    for v in ${envs[@]+"${envs[@]}"}; do e+=(-e "$v"); done
    docker exec ${e[@]+"${e[@]}"} "$BUILD_CONTAINER" "$@" </dev/null
  else
    env ${envs[@]+"${envs[@]}"} "$@" </dev/null
  fi
}
# sum of the n column of one parquet file, and row counts
sum_n() {  # sum_n <parquet path visible inside the container>
  in_r Rscript -e '
    suppressMessages({library(DBI); library(duckdb)})
    con <- dbConnect(duckdb(), dbdir = ":memory:")
    cat(format(dbGetQuery(con, sprintf("SELECT SUM(n)::DOUBLE v FROM read_parquet(\x27%s\x27)", commandArgs(TRUE)[1]))$v, scientific = FALSE))' "$1"
}
n_rows() {  # n_rows <parquet path>
  in_r Rscript -e '
    suppressMessages({library(DBI); library(duckdb)})
    con <- dbConnect(duckdb(), dbdir = ":memory:")
    cat(dbGetQuery(con, sprintf("SELECT COUNT(*)::BIGINT v FROM read_parquet(\x27%s\x27)", commandArgs(TRUE)[1]))$v)' "$1"
}
json_get() {  # json_get <file> <key> : top-level string value
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}

# ---- (a) preflight --------------------------------------------------------------
step "a. preflight"
if [ "$DRY" -eq 0 ]; then
  [ -z "$BUILD_CONTAINER" ] || command -v docker >/dev/null || die "docker not on PATH (or set BUILD_CONTAINER=\"\" to run R here)"
  command -v flock  >/dev/null || die "flock not found"
  command -v python3 >/dev/null || die "python3 not found"
  command -v aws    >/dev/null || die "aws CLI not found"
  command -v curl   >/dev/null || die "curl not found"
  [ "$SKIP_BUILD" -eq 1 ] || [ "$SKIP_TAXONOMY" -eq 1 ] || command -v unzip >/dev/null || die "unzip not found (WoRMS taxonomy step)"
fi
[ -z "${OBIS_GLOBAL:-}" ] || echo "NOTE: ignoring OBIS_GLOBAL=$OBIS_GLOBAL (this script never streams from S3)"

if [ "$TAXONOMY_ONLY" -eq 0 ] && { [ "$SKIP_SYNC" -eq 0 ] || [ "$SKIP_BUILD" -eq 0 ]; }; then
  avail_gb=$(df -BG --output=avail "$OBIS_DIR" 2>/dev/null | tail -1 | tr -dc '0-9' || true)
  avail_gb="${avail_gb:-0}"
  echo "free on $OBIS_DIR: ${avail_gb} GB (need >= ${MIN_FREE_GB} GB)"
  if [ "$avail_gb" -lt "$MIN_FREE_GB" ]; then
    live=$(readlink -f "$OBIS_DIR/obis_h3.duckdb" 2>/dev/null || true)
    msg="only ${avail_gb} GB free on $OBIS_DIR, need ${MIN_FREE_GB} GB.
  A partial sync would silently build a store from a truncated snapshot, so nothing was run.
  Prunable (never the store h3t serves: ${live:-none found}):"
    while read -r f; do
      [ -n "$f" ] || continue
      [ "$(readlink -f "$f")" = "$live" ] && continue
      msg="$msg
    $(du -sh "$f" 2>/dev/null | cut -f1)  $f"
    done < <(ls -1t "$OBIS_DIR"/obis_h3_*.duckdb 2>/dev/null | tail -n +2)
    msg="$msg
    old releases under $DIR_OUT (older ones stay on S3):
$(du -sh "$DIR_OUT"/v* 2>/dev/null | sed 's/^/    /' || true)
    spill dir: $OBIS_TEMP_DIR
  Free space (rm the stores above), then re-run."
    if [ "$DRY" -eq 1 ]; then echo "WOULD FAIL (exit 2): $msg"; else die "$msg" 2; fi
  fi
else
  echo "sync and build both skipped: disk check not needed"
fi
if [ "$SKIP_UPLOAD" -eq 0 ] && [ "$DRY" -eq 0 ]; then
  # fail now, not after hours of build, if S3 credentials are missing
  aws sts get-caller-identity >/dev/null || die "no usable AWS credentials for the upload"
fi

# ---- (a2) WoRMS taxonomy ---------------------------------------------------------
# taxon.parquet only feeds the build, so this runs only when the store is built
tax_meta="$TAXON_PARQUET.json"
if [ "$SKIP_BUILD" -eq 1 ] || [ "$SKIP_TAXONOMY" -eq 1 ]; then
  step "a2. WoRMS taxonomy SKIPPED"
else
  step "a2. WoRMS taxonomy (ChecklistBank dataset $CLB_DATASET)"
  have=""; [ -s "$tax_meta" ] && have=$(json_get "$tax_meta" version 2>/dev/null || true)
  want=$(curl -fsS --max-time 30 "$CLB_API" 2>/dev/null \
         | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null || true)
  echo "taxon.parquet: ${have:-<no version recorded>}; ChecklistBank: ${want:-<unreachable>}"
  if [ -z "$want" ]; then
    [ -f "$TAXON_PARQUET" ] || [ "$DRY" -eq 1 ] || die "ChecklistBank unreachable and no $TAXON_PARQUET to fall back on"
    echo "WARN: keeping the existing taxon.parquet (${have:-unversioned})"
    WORMS_VERSION="$have"
  elif [ "$want" = "$have" ] && [ -f "$TAXON_PARQUET" ]; then
    echo "up to date"
    WORMS_VERSION="$have"
  else
    [[ "$want" =~ ^[0-9A-Za-z._-]+$ ]] || die "unexpected ChecklistBank version '$want'"
    zip="$WORMS_DIR/checklistbank_${CLB_DATASET}_v${want}.zip"
    run mkdir -p "$WORMS_DIR"
    if [ "$DRY" -eq 1 ]; then
      echo "+ (dry-run) curl $CLB_API/archive -> $zip; unzip taxon.txt; build_taxon_parquet.R -> $TAXON_PARQUET"
    else
      [ -s "$zip" ] || { curl -fsSL --retry 3 --max-time 1800 -o "$zip.part" "$CLB_API/archive" && mv "$zip.part" "$zip"; } \
        || die "download of $CLB_API/archive failed"
      txt="$WORMS_DIR/taxon_v${want}.txt"
      unzip -p "$zip" taxon.txt > "$txt" || die "no taxon.txt in $zip"
      in_r OBIS_PKG_ROOT="$PKG_ROOT" Rscript "$PKG_ROOT/data-raw/build_taxon_parquet.R" "$txt" "$TAXON_PARQUET.new"
      n_tax=$(n_rows "$TAXON_PARQUET.new")
      [ "${n_tax:-0}" -gt 1000000 ] || die "new taxon.parquet has only ${n_tax:-0} rows; keeping the old one"
      mv "$TAXON_PARQUET.new" "$TAXON_PARQUET"
      rm -f "$txt"
      python3 -I - "$tax_meta" "$want" "$CLB_DATASET" "$n_tax" "$zip" <<'PY'
import json, sys, datetime
f, v, ds, n, z = sys.argv[1:]
json.dump({"source": f"ChecklistBank dataset {ds} (WoRMS DwC-A)", "version": v, "rows": int(n),
           "archive": z, "built_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},
          open(f, "w"), indent=2)
PY
      echo "taxon.parquet rebuilt: WoRMS $want, $n_tax rows"
    fi
    WORMS_VERSION="$want"
  fi
fi

[ "$TAXONOMY_ONLY" -eq 0 ] || { step "done (--taxonomy-only)"; exit 0; }

# ---- (b) sync -------------------------------------------------------------------
if [ "$SKIP_SYNC" -eq 0 ]; then
  step "b. sync s3://obis-open-data/occurrence/ -> $OCC_DIR"
  SYNC_DATE=$(date -u +%Y%m%d)
  run mkdir -p "$OCC_DIR"
  run aws s3 sync --no-sign-request s3://obis-open-data/occurrence/ "$OCC_DIR/" --only-show-errors
  if [ "$DRY" -eq 0 ]; then
    n_pq=$(find "$OCC_DIR" -name '*.parquet' | wc -l)
    [ "$n_pq" -gt 0 ] || die "sync produced no parquet files in $OCC_DIR"
    echo "synced: $n_pq parquet files, $(du -sh "$OCC_DIR" | cut -f1)"
    echo "$SYNC_DATE" > "$SYNC_MARKER"
  fi
  [ -n "$RELEASE" ] || RELEASE="v$SYNC_DATE"
else
  step "b. sync SKIPPED"
  if [ -z "$RELEASE" ]; then
    [ -s "$SYNC_MARKER" ] || die "--skip-sync without --release and no $SYNC_MARKER from an earlier sync"
    RELEASE="v$(tr -dc '0-9' < "$SYNC_MARKER")"
  fi
fi
[[ "$RELEASE" =~ ^v[0-9]{8}$ ]] || die "release tag must look like v20260828, got '$RELEASE'"
OUT="$DIR_OUT/$RELEASE"
echo "release: $RELEASE   output: $OUT"
[ -z "${GITHUB_OUTPUT:-}" ] || [ "$DRY" -eq 1 ] || echo "release=$RELEASE" >> "$GITHUB_OUTPUT"

# ---- (c) build ------------------------------------------------------------------
if [ "$SKIP_BUILD" -eq 0 ]; then
  step "c. build the store ${BUILD_CONTAINER:+inside $BUILD_CONTAINER}"
  [ "$DRY" -eq 1 ] || [ -n "$(find "$OCC_DIR" -name '*.parquet' -print -quit 2>/dev/null)" ] \
    || die "no parquet at $OCC_DIR; sync first"
  [ "$DRY" -eq 1 ] || [ -f "$TAXON_PARQUET" ] \
    || die "no WoRMS taxon.parquet at $TAXON_PARQUET (manual input; Rscript data-raw/build_taxon_parquet.R)"
  marker=""; [ "$DRY" -eq 1 ] || marker=$(mktemp "$OBIS_DIR/.refresh_build_start.XXXXXX")
  # the build script's own guards, explicit; OBIS_GLOBAL=false forces the local parquet path
  run in_r \
    OBIS_DIR="$OBIS_DIR" OBIS_PKG_ROOT="$PKG_ROOT" \
    OBIS_MEMORY="$OBIS_MEMORY" OBIS_THREADS="$OBIS_THREADS" \
    OBIS_TEMP_DIR="$OBIS_TEMP_DIR" OBIS_MAX_TEMP="$OBIS_MAX_TEMP" \
    OBIS_GLOBAL=false OBIS_SYMLINK=false OBIS_TAXON_PARQUET="$TAXON_PARQUET" \
    Rscript "$PKG_ROOT/data-raw/build_obis_h3_duckdb.R"
  if [ "$DRY" -eq 0 ]; then
    STORE=$(find "$OBIS_DIR" -maxdepth 1 -name 'obis_h3_global_*.duckdb' -newer "$marker" -printf '%T@ %p\n' \
            | sort -n | tail -1 | cut -d' ' -f2-)
    rm -f "$marker"
    [ -n "$STORE" ] && [ -f "$STORE" ] || die "build finished but no new obis_h3_global_*.duckdb in $OBIS_DIR"
  fi
else
  step "c. build SKIPPED"
  if [ -z "${STORE:-}" ]; then
    STORE=$(ls -1t "$OBIS_DIR"/obis_h3_global_*.duckdb 2>/dev/null | head -1 || true)
  fi
  [ "$SKIP_EXPORT" -eq 1 ] || [ "$DRY" -eq 1 ] || [ -f "${STORE:-}" ] \
    || die "no store to export: set STORE=... or build one"
fi
echo "store: ${STORE:-<n/a>}"
[ -z "${GITHUB_OUTPUT:-}" ] || [ "$DRY" -eq 1 ] || [ -z "${STORE:-}" ] || echo "store=$STORE" >> "$GITHUB_OUTPUT"

# ---- (d) export -----------------------------------------------------------------
if [ "$SKIP_EXPORT" -eq 0 ]; then
  step "d. export obis_h3_export_parquet() -> $OUT"
  overwrite=FALSE
  if [ -d "$OUT" ]; then
    if [ ! -f "$OUT/release.json" ]; then
      echo "$OUT is partial (no release.json): replacing it"; overwrite=TRUE   # release.json is written last
    elif [ "${EXPORT_OVERWRITE:-0}" = 1 ]; then
      overwrite=TRUE
    else
      die "$OUT is already complete; pass EXPORT_OVERWRITE=1, choose --release, or --skip-export"
    fi
  fi
  run mkdir -p "$DIR_OUT"
  # source every checked-out R file (they only define functions) so the export is whatever the
  # checkout holds, not whatever version of the package was last installed in the container
  # (a hand-picked subset missed eov.R's obis_eov_label() until 2026-10-12);
  # release.json takes the version from the checkout's DESCRIPTION (OBIS_PKG_ROOT)
  # the WoRMS version goes into release.json only when this run built the store from it
  wv=""; [ "$SKIP_BUILD" -eq 0 ] && wv="$WORMS_VERSION"
  run in_r OBIS_PKG_ROOT="$PKG_ROOT" OBIS_WORMS_VERSION="$wv" Rscript -e '
    a <- commandArgs(TRUE)
    suppressMessages({library(DBI); library(duckdb); library(glue); library(jsonlite)})
    for (f in list.files(file.path(Sys.getenv("OBIS_PKG_ROOT"), "R"), "[.]R$", full.names = TRUE)) source(f)
    con <- obis_store_connect(a[1], read_only = TRUE)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    dbExecute(con, sprintf("SET temp_directory = \x27%s\x27;", a[6]))
    dbExecute(con, sprintf("SET max_temp_directory_size = \x27%s\x27;", a[7]))
    obis_h3_export_parquet(con, a[2], a[3], memory_limit = a[4], threads = as.integer(a[5]),
                           overwrite = identical(a[8], "TRUE"))' \
    "${STORE:-}" "$DIR_OUT" "$RELEASE" "$EXPORT_MEMORY" "$EXPORT_THREADS" \
    "$OBIS_TEMP_DIR" "$OBIS_MAX_TEMP" "$overwrite"
else
  step "d. export SKIPPED"
fi

# ---- (e) validate ---------------------------------------------------------------
step "e. validate $OUT"
if [ "$DRY" -eq 1 ]; then
  echo "(dry-run) would check release.json parses, files.parquet/stats.parquet/taxon_groups.parquet are non-empty,"
  echo "          and sum(n) of all/res=1 (total records) >= ${MIN_PCT}% of the previous release's"
else
  [ -f "$OUT/release.json" ] || die "$OUT/release.json missing: export did not finish" 4
  rel_in_json=$(json_get "$OUT/release.json" release) || die "release.json does not parse" 4
  [ "$rel_in_json" = "$RELEASE" ] || die "release.json says '$rel_in_json', expected '$RELEASE'" 4
  for f in files stats taxon_groups; do
    [ -f "$OUT/$f.parquet" ] || die "$OUT/$f.parquet missing" 4
    n=$(n_rows "$OUT/$f.parquet")
    [ "${n:-0}" -gt 0 ] || die "$f.parquet has no rows" 4
    echo "$f.parquet: $n rows"
  done
  [ -f "$OUT/all/res=1/data_0.parquet" ] || die "$OUT/all/res=1/data_0.parquet missing" 4
  new_total=$(sum_n "$OUT/all/res=1/data_0.parquet")
  echo "total records, new ($RELEASE): $new_total"
  [[ "$new_total" =~ ^[0-9]+$ ]] && [ "$new_total" -gt 0 ] || die "new release has no records (sum(n) = '${new_total:-}')" 4

  # previous release: PREV_RELEASE, else the live latest.json, else the newest other local dir
  prev="${PREV_RELEASE:-}"
  [ -n "$prev" ] || prev=$(curl -fsS --max-time 20 "$PUBLIC_BASE/latest.json" 2>/dev/null \
                           | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["release"])' 2>/dev/null || true)
  [ -n "$prev" ] || prev=$(ls -1d "$DIR_OUT"/v????????  2>/dev/null | xargs -n1 basename | grep -vx "$RELEASE" | sort | tail -1 || true)
  prev_total=""
  if [ -n "$prev" ] && [ "$prev" != "$RELEASE" ]; then
    p="$DIR_OUT/$prev/all/res=1/data_0.parquet"
    if [ ! -f "$p" ]; then
      mkdir -p "$DIR_OUT/.cmp"; p="$DIR_OUT/.cmp/${prev}_all_res1.parquet"
      curl -fsS --max-time 300 -o "$p" "$PUBLIC_BASE/$prev/all/res%3D1/data_0.parquet" 2>/dev/null \
        || curl -fsS --max-time 300 -o "$p" "$PUBLIC_BASE/$prev/all/res=1/data_0.parquet" 2>/dev/null \
        || { rm -f "$p"; p=""; }
    fi
    [ -z "$p" ] || prev_total=$(sum_n "$p" 2>/dev/null || true)
  fi
  if ! [[ "$prev_total" =~ ^[0-9]+$ ]] || [ "$prev_total" -le 0 ]; then
    [ "${ALLOW_NO_PREV:-0}" = 1 ] || die "cannot read the previous release's total (tried '${prev:-none}'); set PREV_RELEASE or ALLOW_NO_PREV=1" 4
    echo "WARN: no previous release to compare with; continuing (ALLOW_NO_PREV=1)"
  else
    echo "total records, previous ($prev): $prev_total"
    pct=$(( new_total * 100 / prev_total ))
    echo "new / previous = ${pct}% (minimum ${MIN_PCT}%)"
    [ "$pct" -ge "$MIN_PCT" ] || die "new release has ${pct}% of the previous release's records (< ${MIN_PCT}%): not uploading" 4
  fi
  echo "validation ok"
fi

# ---- (f) upload -----------------------------------------------------------------
DEST="s3://$S3_BUCKET/$S3_PREFIX/$RELEASE/"
if [ "$SKIP_UPLOAD" -eq 0 ]; then
  step "f. upload -> $DEST (no --delete)"
  run aws s3 sync "$OUT/" "$DEST" --only-show-errors
  if [ "$DRY" -eq 0 ]; then
    n_local=$(find "$OUT" -type f | wc -l)
    n_remote=$(aws s3 ls "$DEST" --recursive | wc -l)
    echo "files: local $n_local, on S3 $n_remote"
    [ "$n_remote" -ge "$n_local" ] || die "S3 holds fewer files ($n_remote) than the export ($n_local): latest.json NOT written"
  fi

  # ---- (g) latest.json, only after everything above succeeded -------------------
  step "g. latest.json"
  if [ "$DRY" -eq 0 ]; then
    latest="$DIR_OUT/latest.json"
    python3 -I - "$OUT/release.json" "$RELEASE" "$PUBLIC_BASE" > "$latest" <<'PY'
import json, sys
rj = json.load(open(sys.argv[1]))
print(json.dumps({"release": sys.argv[2],
                  "base": f"{sys.argv[3]}/{sys.argv[2]}/",
                  "obis_snapshot": rj["obis_snapshot"],
                  "built_at": rj["built_at"]}, indent=2))
PY
    cat "$latest"
  else
    latest="$DIR_OUT/latest.json"
  fi
  run aws s3 cp "$latest" "s3://$S3_BUCKET/$S3_PREFIX/latest.json" \
    --content-type application/json --cache-control max-age=300
else
  step "f/g. upload and latest.json SKIPPED"
fi

# ---- (h) summary ----------------------------------------------------------------
step "h. summary"
cat <<EOS
release:   $RELEASE
store:     ${STORE:-<n/a>}
export:    $OUT ($(du -sh "$OUT" 2>/dev/null | cut -f1 || echo '?'))
s3:        $DEST
latest:    $PUBLIC_BASE/latest.json
dry-run:   $DRY
next (manual, needs sudo): data-raw/deploy_obis_h3.sh --skip-sync --skip-build --store ${STORE:-<store>} --yes
rollback:  re-publish an older latest.json (older releases stay on S3):
           aws s3 cp <(echo '{"release":"vOLD","base":"$PUBLIC_BASE/vOLD/","obis_snapshot":"YYYY-MM-DD","built_at":"..."}') s3://$S3_BUCKET/$S3_PREFIX/latest.json --content-type application/json --cache-control max-age=300
EOS
