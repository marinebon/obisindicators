#!/usr/bin/env bash
# Run the monthly obis-h3 refresh (data-raw/refresh_obis_h3.sh) inside its Docker image on a Mac
# (the Mac mini), with the data on an external drive. Scheduled by oceanmetrics/erddap-places
# .github/workflows/obis-h3.yml (runner `macmini`); also fine to run by hand, e.g. in tmux.
#
# Usage:
#   data-raw/run_refresh_docker.sh [--keep-vm] [--no-msens] [refresh_obis_h3.sh args...]
#
#   --keep-vm    leave the Colima VM running afterwards (default: stop it if this run started it,
#                so the mini's memory is free for other work between runs)
#   --no-msens   do not copy the new store to msens for the h3t service
#   the rest goes to refresh_obis_h3.sh unchanged: --dry-run, --skip-sync, --skip-build,
#   --skip-export, --skip-upload, --release vYYYYMMDD
#
# Steps: check the drive is mounted -> start the Colima VM (profile obis-h3; Docker runtime, no
# GUI needed) -> docker build data-raw/docker (cached) -> docker run --rm the refresh with
#   $DATA_ROOT      -> /share/data                              (obis/, obis-h3/, derived/)
#   this checkout   -> /share/github/marinebon/obisindicators   (read-only; the R code is sourced)
#   $AWS_DIR        -> /root/.aws                               (read-only)
# -> after a published release, rsync the new store to msens (h3t reads it; the swap stays manual:
# deploy_obis_h3.sh there) -> write $DATA_ROOT/obis/log/refresh_YYYYMMDD.done -> stop the VM.
#
# Exit codes: those of refresh_obis_h3.sh (0 ok, 1 failed, 2 disk, 3 another run, 4 validation),
# and 5 when the drive or Docker is not available. A failed copy to msens only warns.
#
# Env (defaults): DATA_ROOT=/Volumes/msens_big/_big/obis  AWS_DIR=~/.aws  AWS_PROFILE (passed on)
#   COLIMA_PROFILE=obis-h3 COLIMA_CPU=8 COLIMA_MEMORY=24 (GiB) COLIMA_DISK=60 (GiB, the VM's own disk)
#   IMAGE=obis-h3-refresh  MSENS_HOST=msens  MSENS_OBIS_DIR=/share/data/obis
#   passed into the container when set: OBIS_MEMORY (16GB) OBIS_THREADS (6) OBIS_MAX_TEMP (200GB)
#   EXPORT_MEMORY (12GB) EXPORT_THREADS (6) MIN_FREE_GB MIN_PCT PREV_RELEASE ALLOW_NO_PREV
#   EXPORT_OVERWRITE STORE (a path under /share/data)
#   OBIS_PLACE_COLLECTIONS GAZETTEER_BASE (the opt-in per-place layer; see refresh_obis_h3.sh)

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

PKG_ROOT=$(cd "$(dirname "$0")/.." && pwd)
DATA_ROOT="${DATA_ROOT:-/Volumes/msens_big/_big/obis}"
AWS_DIR="${AWS_DIR:-$HOME/.aws}"
COLIMA_PROFILE="${COLIMA_PROFILE:-obis-h3}"
COLIMA_CPU="${COLIMA_CPU:-8}"
COLIMA_MEMORY="${COLIMA_MEMORY:-24}"
COLIMA_DISK="${COLIMA_DISK:-60}"
IMAGE="${IMAGE:-obis-h3-refresh}"
MSENS_HOST="${MSENS_HOST:-msens}"
MSENS_OBIS_DIR="${MSENS_OBIS_DIR:-/share/data/obis}"
CTR_NAME=obis-h3-refresh

KEEP_VM=0; NO_MSENS=0; DRY=0; SKIP_UPLOAD=0
args=()
for a in "$@"; do
  case "$a" in
    --keep-vm)     KEEP_VM=1 ;;
    --no-msens)    NO_MSENS=1 ;;
    -h|--help)     sed -n '2,31p' "$0"; exit 0 ;;
    *)             args+=("$a")
                   [ "$a" = --dry-run ] && DRY=1
                   [ "$a" = --skip-upload ] && SKIP_UPLOAD=1 ;;
  esac
done

die()  { echo "ERROR: $1" >&2; exit "${2:-1}"; }
say()  { echo "=== $(date -u +%H:%M:%SZ) $* ==="; }
dk()   { docker --context "colima-$COLIMA_PROFILE" "$@"; }

# ---- the drive, not a folder that happens to exist on the internal disk ---------------------
[ -d "$DATA_ROOT" ] || die "$DATA_ROOT does not exist (is the external drive mounted? first run: see data-raw/README.md)" 5
mnt=$(df -P "$DATA_ROOT" | awk 'NR == 2 {print $6}')
[ "$mnt" != "/" ] && [ "$mnt" != "/System/Volumes/Data" ] \
  || die "$DATA_ROOT is on the internal disk ($mnt), not the external drive" 5
[ -w "$DATA_ROOT" ] || die "$DATA_ROOT is not writable by $(id -un)" 5
mkdir -p "$DATA_ROOT/obis/log" "$DATA_ROOT/obis-h3" "$DATA_ROOT/derived"
[ -d "$AWS_DIR" ] || die "no AWS config at $AWS_DIR (the upload needs credentials)" 5
command -v colima >/dev/null && command -v docker >/dev/null \
  || die "colima and docker are needed: brew install colima docker" 5

# ---- the VM: started here, stopped here (unless it was already running, or --keep-vm) --------
started=0
if colima status --profile "$COLIMA_PROFILE" >/dev/null 2>&1; then
  say "colima $COLIMA_PROFILE already running"
else
  say "colima start $COLIMA_PROFILE (${COLIMA_CPU} CPU, ${COLIMA_MEMORY} GiB)"
  # Colima refuses overlapping mounts, so a checkout inside $DATA_ROOT rides on that mount
  mounts=(--mount "$DATA_ROOT:w" --mount "$AWS_DIR")
  case "$PKG_ROOT/" in "$DATA_ROOT"/*) ;; *) mounts+=(--mount "$PKG_ROOT") ;; esac
  colima start --profile "$COLIMA_PROFILE" --vm-type vz --mount-type virtiofs \
    --cpu "$COLIMA_CPU" --memory "$COLIMA_MEMORY" --disk "$COLIMA_DISK" "${mounts[@]}" \
    || die "colima start failed" 5
  started=1
fi
stop_vm() {
  if [ "$started" -eq 1 ] && [ "$KEEP_VM" -eq 0 ]; then
    say "colima stop $COLIMA_PROFILE"
    colima stop --profile "$COLIMA_PROFILE" || true
  fi
}
trap stop_vm EXIT

if dk ps -a --format '{{.Names}}' | grep -qx "$CTR_NAME"; then
  die "a container named $CTR_NAME exists: another refresh is running (or: docker --context colima-$COLIMA_PROFILE rm $CTR_NAME)" 3
fi

# ---- image (cached unless data-raw/docker changed) -----------------------------------------
say "docker build $IMAGE"
dk build --quiet -t "$IMAGE" "$PKG_ROOT/data-raw/docker" >/dev/null
dk run --rm --entrypoint Rscript "$IMAGE" -e 'cat("R", as.character(getRversion()), "duckdb", as.character(packageVersion("duckdb")), "\n")'

# ---- the refresh ----------------------------------------------------------------------------
out="$DATA_ROOT/obis/.refresh_output"
: > "$out"
envs=(-e BUILD_CONTAINER= -e LOCK_FILE=/tmp/refresh_obis_h3.lock
      -e GITHUB_OUTPUT=/share/data/obis/.refresh_output
      -e "OBIS_MEMORY=${OBIS_MEMORY:-16GB}" -e "OBIS_THREADS=${OBIS_THREADS:-6}"
      -e "OBIS_MAX_TEMP=${OBIS_MAX_TEMP:-200GB}"
      -e "EXPORT_MEMORY=${EXPORT_MEMORY:-12GB}" -e "EXPORT_THREADS=${EXPORT_THREADS:-6}"
      -e AWS_PROFILE -e "AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}")
for v in MIN_FREE_GB MIN_PCT PREV_RELEASE ALLOW_NO_PREV EXPORT_OVERWRITE STORE OBIS_PLACE_COLLECTIONS GAZETTEER_BASE; do
  [ -z "${!v:-}" ] || envs+=(-e "$v=${!v}")
done

say "refresh_obis_h3.sh ${args[*]+${args[*]}}"
set +e
dk run --rm --name "$CTR_NAME" \
  -v "$DATA_ROOT:/share/data" \
  -v "$PKG_ROOT:/share/github/marinebon/obisindicators:ro" \
  -v "$AWS_DIR:/root/.aws:ro" \
  "${envs[@]}" "$IMAGE" ${args[@]+"${args[@]}"}
rc=$?
set -e

# the script's outputs (log, release, store) with container paths turned into host paths
if [ -s "$out" ]; then
  sed "s#=/share/data#=$DATA_ROOT#" "$out" > "$out.host"
  [ -z "${GITHUB_OUTPUT:-}" ] || cat "$out.host" >> "$GITHUB_OUTPUT"
fi
get() { [ -s "$out.host" ] && sed -n "s/^$1=//p" "$out.host" | tail -1; }
[ "$rc" -eq 0 ] || die "refresh_obis_h3.sh exited $rc (log: $(get log || true))" "$rc"
[ "$DRY" -eq 0 ] || { say "dry run done"; exit 0; }

# ---- the store to msens, for h3t (only after a published release) -------------------------
store=$(get store || true)
if [ "$NO_MSENS" -eq 1 ] || [ "$SKIP_UPLOAD" -eq 1 ] || [ -z "$store" ]; then
  say "store not copied to msens (--no-msens, --skip-upload or no store)"
elif ssh -o BatchMode=yes -o ConnectTimeout=15 "$MSENS_HOST" true 2>/dev/null; then
  say "rsync $(basename "$store") -> $MSENS_HOST:$MSENS_OBIS_DIR/"
  rsync -a --partial "$store" "$MSENS_HOST:$MSENS_OBIS_DIR/" \
    && echo "next, on msens (sudo): data-raw/deploy_obis_h3.sh --skip-sync --skip-build --store $MSENS_OBIS_DIR/$(basename "$store") --yes" \
    || echo "WARN: rsync to $MSENS_HOST failed; h3t keeps its current store" >&2
else
  echo "WARN: cannot ssh to $MSENS_HOST; copy $store there by hand for h3t" >&2
fi

date -u +%Y-%m-%dT%H:%M:%SZ > "$DATA_ROOT/obis/log/refresh_$(date -u +%Y%m%d).done"
say "done: release $(get release || echo '?')"
