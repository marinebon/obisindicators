# data-raw

Build and deploy scripts for the OBIS H3 store and the `obis-h3` web release. Run them on the msens host
(`ssh msens`), not on a laptop. Excluded from the built package (`.Rbuildignore`).

| script | does |
|---|---|
| `build_taxon_parquet.R` | WoRMS `taxon.parquet` (**manual input**, see below) |
| `build_obis_h3_duckdb.R` | builds `/share/data/obis/obis_h3_global_vYYYYMMDD.duckdb` from the local OBIS parquet snapshot (runs in the `plumber` container) |
| `deploy_obis_h3.sh` | swaps the store the `h3t` tile service serves (needs sudo), restarts h3t, verifies |
| `refresh_obis_h3.sh` | the monthly `obis-h3` release for the obis-hex app: sync, build, export, validate, upload, `latest.json` |

## Monthly `obis-h3` refresh (`refresh_obis_h3.sh`)

The obis-hex app reads a static release of hive-partitioned Parquet from
`s3://oceanmetrics.io-public/obis-h3/<release>/` (public
`https://s3.us-east-1.amazonaws.com/oceanmetrics.io-public/obis-h3/<release>/`). The pointer to the current
release is `obis-h3/latest.json`:

```json
{"release": "v20261001", "base": "https://s3.us-east-1.amazonaws.com/oceanmetrics.io-public/obis-h3/v20261001/",
 "obis_snapshot": "2026-10-01", "built_at": "2026-10-02T04:12:09Z"}
```

`latest.json` is written **last**, with `Cache-Control: max-age=300`, only after the release is uploaded and its
file count checked, so a failed run never moves the pointer. Release folders are immutable and never deleted,
so older releases stay for rollback.

```bash
data-raw/refresh_obis_h3.sh                    # full run (hours; ~93 GB sync, build, export, upload)
data-raw/refresh_obis_h3.sh --dry-run          # print every step, change nothing
data-raw/refresh_obis_h3.sh --skip-sync --skip-build --release v20260828   # re-export + upload from disk
```

Flags: `--skip-sync`, `--skip-build`, `--skip-export`, `--skip-upload` (also skips `latest.json`),
`--release vYYYYMMDD` (default the UTC date of the sync, recorded in `/share/data/obis/occurrence.synced_at`),
`--dry-run`. Paths and limits are env-overridable (list in the script header). Log:
`/share/data/obis/log/refresh_YYYYMMDD.log`. One run at a time (`flock`, exit 3 if locked).

Steps:

1. **Preflight**: at least 110 GB free on `/share/data/obis` (`MIN_FREE_GB`), else exit 2 naming the prunable
   old stores. A partial sync would silently build from a truncated snapshot. Also checks AWS credentials.
2. **Sync** `s3://obis-open-data/occurrence/` to `/share/data/obis/occurrence/` (anonymous).
3. **Build** with `docker exec plumber Rscript data-raw/build_obis_h3_duckdb.R` from the local parquet, with the
   guards memory 7GB, 2 threads, 20GB spill cap (`OBIS_MEMORY`, `OBIS_THREADS`, `OBIS_MAX_TEMP`). It never
   sets `OBIS_GLOBAL=true`: streaming from S3 OOM-wedged msens on 2026-06-23.
4. **Export** `obis_h3_export_parquet()` (from `R/export.R`, sourced from the checkout) into
   `/share/data/obis-h3/<release>/` with `memory_limit` 6GB and 2 threads. A half-written output folder
   (no `release.json`) is replaced; a complete one needs `EXPORT_OVERWRITE=1`.
5. **Validate**: `release.json` parses and carries the release tag; `files.parquet`, `stats.parquet` and
   `taxon_groups.parquet` are non-empty; total records (the sum of `n` over `all/res=1`, since every record
   falls in exactly one res-1 cell) is at least 90% of the previous release's (`MIN_PCT`). Else exit 4,
   nothing uploaded. The previous release is `PREV_RELEASE`, else the one `latest.json` names.
6. **Upload** `aws s3 sync` of the release folder, no `--delete`, then compare file counts.
7. **`latest.json`**.

Not automated (needs sudo): pointing the `h3t` tile service at the new store, after a successful run:

```bash
data-raw/deploy_obis_h3.sh --skip-sync --skip-build --store /share/data/obis/obis_h3_global_vYYYYMMDD.duckdb --yes
```

### Prerequisites and manual inputs

- `R/export.R` (`obis_h3_export_parquet()`) lives on the `export-parquet` branch until it is merged to `main`;
  the checkout at `/share/github/marinebon/obisindicators` must be on a branch that has it.
- The `plumber` container needs `/share` mounted, the `obisindicators` package installed (only for
  `packageVersion()` in `release.json`), and `glue`, `jsonlite`, `duckdb`, `httr2`.
- `/share/data/obis/log` and `/share/data/obis-h3` must exist and be writable by the user that runs the script
  and by the container.
- **`/share/data/derived/taxon.parquet` (WoRMS) is a manual input**, refreshed separately with
  `Rscript data-raw/build_taxon_parquet.R` when WoRMS changes. The monthly job reuses whatever is there and the
  build aborts if it is missing.
- Scheduling: `oceanmetrics/erddap-places` `.github/workflows/obis-h3.yml` (1st of the month, 03:17 UTC, runner
  `msens`). See that repo's `catalog/README.md`, "Where it runs".

### Rollback

Older releases stay on S3. To point the app back, overwrite `latest.json` with the older release's values (the
snapshot and build date are in that release's `release.json`):

```bash
aws s3 cp s3://oceanmetrics.io-public/obis-h3/vOLD/release.json -   # read obis_snapshot, built_at
echo '{"release":"vOLD","base":"https://s3.us-east-1.amazonaws.com/oceanmetrics.io-public/obis-h3/vOLD/","obis_snapshot":"YYYY-MM-DD","built_at":"..."}' \
  | aws s3 cp - s3://oceanmetrics.io-public/obis-h3/latest.json --content-type application/json --cache-control max-age=300
```
