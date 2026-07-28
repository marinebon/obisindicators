#!/usr/bin/env bash
# Host-side entrypoint for the OBIS H3 store: sync -> build -> swap -> restart
# -> VERIFY. Run this on the msens HOST, not inside a container.
#
# Why a host script rather than doing it from R: the build runs inside the
# `plumber` container, which has no docker CLI, so the restart it used to
# attempt failed with "sh: 1: docker: not found" and the build still exited 0.
# h3t holds the store's file handle open, so a skipped restart leaves the
# service serving the PREVIOUS store while the symlink claims otherwise.
#
# Every step here either succeeds or aborts, and the deploy is confirmed by
# asserting a POST-CONDITION rather than trusting a command's exit code: the
# mtime h3t reports at /h3t/health must equal the mtime of the file we just
# published. That is what catches the failure modes that look like success:
#   - `docker compose up -d h3t` is a NO-OP when the image is cache-identical
#     (prints "Container h3t Running" and keeps the old handle) -> use restart.
#   - a Varnish ban that silently does nothing.
#   - a symlink swap that pointed somewhere unexpected.
#
# Usage:
#   ./deploy_obis_h3.sh [--skip-sync] [--skip-build] [--store PATH] [--yes]
#
#   --skip-sync    don't re-sync parquet from S3 (use what's on disk)
#   --skip-build   don't rebuild; just deploy --store (or the newest global store)
#   --store PATH   deploy this specific .duckdb (implies --skip-build)
#   --yes          don't prompt before swapping the live symlink
#
# Env: OBIS_DIR (/share/data/obis), SERVER_DIR, PKG_ROOT, H3T_URL,
#      SYNC_REQUIRED_GB (110), BUILD_CONTAINER (plumber)

set -euo pipefail

OBIS_DIR="${OBIS_DIR:-/share/data/obis}"
OCC_DIR="${OCC_DIR:-$OBIS_DIR/occurrence}"
SERVER_DIR="${SERVER_DIR:-/share/github/MarineSensitivity/server}"
PKG_ROOT="${PKG_ROOT:-/share/github/marinebon/obisindicators}"
H3T_URL="${H3T_URL:-http://127.0.0.1:8889}"
BUILD_CONTAINER="${BUILD_CONTAINER:-plumber}"
# OBIS open-data occurrence export is ~96 GB; leave headroom for DuckDB spill
SYNC_REQUIRED_GB="${SYNC_REQUIRED_GB:-110}"
LINK="$OBIS_DIR/obis_h3.duckdb"
SENTINEL="$OBIS_DIR/RESTART_REQUIRED"

SKIP_SYNC=0; SKIP_BUILD=0; STORE=""; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-sync)  SKIP_SYNC=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --store)      STORE="${2:?--store needs a path}"; SKIP_BUILD=1; shift ;;
    --yes|-y)     ASSUME_YES=1 ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "=== $* ==="; }

# ---- 0. preflight -----------------------------------------------------------
step "0. preflight"
command -v docker >/dev/null || die "docker not on PATH — run this on the HOST, not in a container"
[ -d "$SERVER_DIR" ] || die "SERVER_DIR not found: $SERVER_DIR"
docker compose -f "$SERVER_DIR/docker-compose.yml" ps h3t >/dev/null \
  || die "cannot reach the h3t compose service"
echo "docker: ok   server_dir: $SERVER_DIR"

avail_gb=$(df -BG --output=avail "$OBIS_DIR" | tail -1 | tr -dc '0-9')
echo "free space on $OBIS_DIR: ${avail_gb} GB"

# ---- 1. sync parquet from S3 (optional) -------------------------------------
if [ "$SKIP_SYNC" -eq 0 ]; then
  step "1. sync OBIS parquet -> $OCC_DIR"
  # The disk check is the whole point: a partial sync produces a store built
  # from a TRUNCATED snapshot, which looks fine and is silently wrong.
  if [ "$avail_gb" -lt "$SYNC_REQUIRED_GB" ]; then
    die "need ~${SYNC_REQUIRED_GB} GB free for the OBIS sync, have ${avail_gb} GB.
     A partial sync would silently build a store from an incomplete snapshot.
     Free space or grow the volume first, then re-run.
     Reclaim candidates:  du -sh $OBIS_DIR/*.duckdb  /share/data/*"
  fi
  command -v aws >/dev/null || die "aws CLI not found — needed for the parquet sync"
  mkdir -p "$OCC_DIR"
  aws s3 sync --no-sign-request s3://obis-open-data/occurrence/ "$OCC_DIR/"
  n_pq=$(find "$OCC_DIR" -name '*.parquet' | wc -l)
  [ "$n_pq" -gt 0 ] || die "sync produced no parquet files in $OCC_DIR"
  echo "synced: $n_pq parquet files"
else
  step "1. sync SKIPPED (--skip-sync)"
fi

# ---- 2. build ---------------------------------------------------------------
if [ "$SKIP_BUILD" -eq 0 ]; then
  step "2. build store (inside the $BUILD_CONTAINER container)"
  n_pq=$(find "$OCC_DIR" -name '*.parquet' 2>/dev/null | wc -l)
  [ "$n_pq" -gt 0 ] || die "no parquet at $OCC_DIR — sync first, or pass --store"
  docker exec \
    -e OBIS_DIR="$OBIS_DIR" \
    "$BUILD_CONTAINER" Rscript "$PKG_ROOT/data-raw/build_obis_h3_duckdb.R" </dev/null
else
  step "2. build SKIPPED"
fi

# ---- 3. choose + publish the store ------------------------------------------
step "3. publish store"
if [ -z "$STORE" ]; then
  STORE=$(ls -1t "$OBIS_DIR"/obis_h3_global_*.duckdb 2>/dev/null | head -1) \
    || die "no obis_h3_global_*.duckdb found in $OBIS_DIR"
fi
[ -f "$STORE" ] || die "store not found: $STORE"
prev=$(readlink -f "$LINK" 2>/dev/null || echo "(none)")
echo "current: $prev"
echo "new:     $STORE"

if [ "$prev" = "$(readlink -f "$STORE")" ]; then
  echo "symlink already points at the target; will still restart + verify"
elif [ "$ASSUME_YES" -eq 0 ]; then
  read -r -p "swap the live symlink? [y/N] " ans </dev/tty
  case "$ans" in [yY]*) ;; *) die "aborted by user" ;; esac
fi
sudo ln -sfn "$STORE" "$LINK"
[ "$(readlink -f "$LINK")" = "$(readlink -f "$STORE")" ] || die "symlink swap did not take"
echo "symlink -> $(readlink "$LINK")"

# ---- 4. restart h3t ---------------------------------------------------------
step "4. restart h3t"
# `up -d` is deliberately NOT used: when the image is cache-identical it is a
# no-op ("Container h3t Running") and the container keeps the OLD file handle.
sudo docker compose -f "$SERVER_DIR/docker-compose.yml" restart h3t

# ---- 5. VERIFY the swap actually took effect --------------------------------
step "5. verify"
want_mtime=$(stat -c %Y "$STORE")
got_mtime=""
for _ in $(seq 1 30); do
  health=$(curl -sSf --max-time 5 "$H3T_URL/h3t/health" 2>/dev/null || true)
  if [ -n "$health" ]; then
    got_mtime=$(printf '%s' "$health" | grep -o '"mtime":"[0-9.]*"' | head -1 | tr -dc '0-9.')
    got_mtime=${got_mtime%%.*}
    [ -n "$got_mtime" ] && break
  fi
  sleep 5
done
[ -n "$got_mtime" ] || die "h3t never became healthy after restart"
echo "store mtime:  $want_mtime"
echo "h3t reports:  $got_mtime"
[ "$want_mtime" = "$got_mtime" ] || die "h3t is STILL serving a different store
     (expected mtime $want_mtime, got $got_mtime). The restart did not take —
     do NOT assume this deploy succeeded."

# ---- 6. flush Varnish -------------------------------------------------------
step "6. flush Varnish"
sudo docker compose -f "$SERVER_DIR/docker-compose.yml" exec -T h3tcache \
  varnishadm 'ban req.url ~ "^/h3t/"'
echo "cache banned"

# ---- 7. done ----------------------------------------------------------------
rm -f "$SENTINEL"
step "deploy complete"
echo "serving: $STORE"
echo "rollback: sudo ln -sfn $prev $LINK && $0 --skip-sync --skip-build --store $prev --yes"
