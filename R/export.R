# export an obis_h3 DuckDB store to hive-partitioned Parquet for a serverless
# web app (static hosting + DuckDB-WASM + deck.gl H3HexagonLayer). the
# precomputed layers are copied as-is; the per-decade layers are computed here
# with the same SQL (.h3t_indicators_sql()) that builds idx_h3 / idx_h3_eov.

# columns of every indicator parquet file, documented in release.json ----
EXPORT_COLUMNS <- list(
  h3      = "H3 cell index as a lowercase hex string (deck.gl H3HexagonLayer getHexagon)",
  cell_id = "H3 cell index as BIGINT (same cell as h3)",
  n       = "number of occurrence records",
  sp      = "species richness (distinct species names)",
  shannon = "Shannon diversity H' = -sum(p_i ln p_i) over species",
  simpson = "Simpson index sum(p_i^2) over species",
  es      = "Hurlbert expected number of species in a random draw of 50 records, ES(50); NULL where n < 50")

EXPORT_VARS <- c("n", "sp", "shannon", "simpson", "es")

# max partitions written by one COPY (open files; DuckDB's own default cap)
EXPORT_MAX_OPEN <- 100L

#' Export an obis_h3 store to hive-partitioned Parquet
#'
#' Writes the indicator layers of a store built by [build_obis_h3_duckdb()] to
#' a directory of hive-partitioned Parquet files that a static web app can read
#' directly with DuckDB-WASM (one small file per map layer and H3 resolution):
#'
#' ```
#' <dir_out>/<release>/
#'   release.json                              build metadata, row counts, layout, columns, file manifest
#'   all/res=<1..5>/data_0.parquet             idx_h3 (all taxa, all years)
#'   all/res=<6,7>/p=<parent>/data_0.parquet   the fine res, one file per parent cell
#'   eov/eov=<eov>/res=<r>/data_0.parquet      idx_h3_eov
#'   taxon/rank=<rank>/taxon=<taxon>/res=<r>/  idx_h3_taxon (phylum / class / order / family)
#'   decade/all/decade=<yyy0>/res=<r>/         per decade, all taxa  (res in res_decade)
#'   decade/eov/eov=<eov>/decade=<yyy0>/res=<r>/  per decade and EOV (res in res_decade)
#'   place/coll=<slug>/data_0.parquet          per-place pooled indicators (only with place_collections)
#'   stats.parquet                             value ranges per layer x key x res x variable
#'   taxon_groups.parquet                      the taxa and EOVs available, with totals and paths
#'   files.parquet                             manifest: layer, path, url_path, rows, bytes per file
#' ```
#'
#' Every indicator file has the columns `h3` (lowercase hex string), `cell_id`,
#' `n`, `sp`, `shannon`, `simpson`, `es`; the partition keys live in the path
#' (read with `hive_partitioning = true`). The decade layers are computed from
#' `occ_h3` with the same SQL builder as `idx_h3` / `idx_h3_eov` (so the math is
#' identical to the store): `n` = records, `sp` = distinct species, Shannon,
#' Simpson and ES(`esn`), grouped by cell and `decade = floor(date_year / 10) *
#' 10`; records without a year are left out of the decade layers. EOV membership
#' is the store's `eov` table (`occ_h3.aphiaid = eov.taxonID`), as in
#' [obis_eov_bake()]. Layers whose source tables are missing (e.g. no
#' `idx_h3_eov` in a store without taxonomy) are skipped with a message.
#'
#' Partition values are percent-encoded by DuckDB (a space becomes `%20`), and
#' DuckDB decodes them on read. A static web server decodes the URL once, so a
#' browser must request the on-disk name with `%` itself encoded (`%2520`);
#' `taxon_groups.parquet` carries both `path` (on disk) and `url_path` (to
#' fetch), and `files.parquet` lists every file with both forms. Each partition
#' is exactly one `data_0.parquet`.
#'
#' **Parent partitions for the fine resolutions.** A whole res-7 layer is tens
#' of MB, too much for a browser to load at once, so the resolutions named in
#' `parent_res` are split by parent cell: every row of `all/res=7/` goes to
#' `all/res=7/p=<h3 of its res-3 parent>/data_0.parquet` (default res 6 by its
#' res-2 parent, res 7 by its res-3 parent), and a viewer loads only the parent
#' cells that cover its viewport. The taxon layer uses `parent_res_taxon`
#' (default the res-0 base cell: res-3 parents would make over a million
#' files across ~5k taxa). A (layer key, res) with at most `parent_min_rows`
#' rows stays one whole file, since splitting it would only add requests. The
#' decade layers are never split (their default resolutions are 1-5).
#' `files.parquet` has a `parent` column (the partition's parent cell, NULL for
#' a whole file; its resolution is the parent resolution), and each layer in
#' `release.json` lists the `parent_res` actually used.
#'
#' **Place layer (optional).** With `place_collections`, each gazetteer
#' collection gets one file, `place/coll=<slug>/data_0.parquet`, with the
#' indicators of every place pooled from its res-7 member cells, records
#' weighted by each cell's share of area inside the place
#' ([obis_place_indicators()]): columns `place_id`, `layer` (`all` | `eov`),
#' `key` ('' or the EOV), `decade` (NULL = all years, else the decades above),
#' `n` (fractional), `sp`, `shannon`, `simpson`, `es`, `cells`, `area`. These
#' are true per-place indices of the pooled, area-weighted counts, not means of
#' hexagon values. The files are listed in `files.parquet` (layer `place`) and
#' `release.json` (`layers$place`, with each collection's membership version);
#' `stats.parquet` does not cover them.
#'
#' `stats.parquet` has one row per (`layer`, `key`, `decade`, `res`,
#' `variable`) with `min`, `p02`, `p50`, `p98`, `max` and `n_cells` (cells with
#' a non-NULL value; a variable NULL everywhere in a partition gets a row with
#' NULL ranges and `n_cells` 0), for colour ramps. `key` is the EOV or taxon
#' name ('' for the all-taxa layers), `rank` the taxon rank ('' otherwise),
#' `decade` NA outside the decade layers.
#'
#' @param con connection from [obis_store_connect()] (read-only is fine).
#' @param dir_out output directory; files go under `dir_out/release/`.
#' @param release release tag, e.g. `"v20260728"` (the date of the OBIS sync
#'   the store was built from); recorded in `release.json`. Its
#'   `obis_snapshot` is the environment variable `OBIS_DATA_DATE` (the newest
#'   OBIS object's date, which `refresh_obis_h3.sh` passes) when that is a
#'   `YYYY-MM-DD` date, else the date in the tag.
#' @param res_decade H3 resolutions for the decade layers (default 1-5).
#' @param parent_res named integer vector, fine resolution -> parent
#'   resolution, for the `all` and `eov` layers: those resolutions are written
#'   one file per parent cell (`res=<r>/p=<parent>/`). Default
#'   `c("6" = 2L, "7" = 3L)`; `NULL` writes every resolution whole.
#' @param parent_res_taxon the same for the taxon layer (default
#'   `c("6" = 0L, "7" = 0L)`, the base cell).
#' @param parent_min_rows a (layer key, res) with at most this many rows is
#'   written whole even when its res is in `parent_res` (default 50000).
#' @param max_open max partitions written by one COPY (default 100); each open
#'   partition holds a file open, so keep it under the process limit
#'   (`ulimit -n`, 256 on macOS by default).
#' @param compression Parquet compression codec (default `"zstd"`).
#' @param overwrite replace an existing `dir_out/release/` (default FALSE: stop).
#' @param decades decades (first year) to export in the decade layers; default
#'   1960-2020. NULL exports every decade present.
#' @param esn expected sample size for ES(n) in the decade layers; default 50
#'   (as in the store).
#' @param place_collections optional named list (or character vector), slug =
#'   the gazetteer collection's membership (a directory or URL, its
#'   `membership.json`, or anything [obis_place_indicators()] takes as
#'   `membership`), e.g. `list(eez = "<gazetteer base>/eez")`. Default `NULL`:
#'   no place layer.
#' @param memory_limit optional DuckDB `memory_limit` (e.g. `"24GB"`).
#' @param threads optional DuckDB thread count (e.g. `8`).
#' @param verbose print progress and the summary (default TRUE).
#'
#' @return invisibly, a character vector of the files written (absolute paths).
#' @concept store
#' @export
#' @examples
#' \dontrun{
#' con <- obis_store_connect("~/data/obis/obis_h3.duckdb")
#' obis_h3_export_parquet(con, "~/data/obis-h3", "v20260728")
#' }
obis_h3_export_parquet <- function(
  con,
  dir_out,
  release,
  res_decade       = 1:5,
  parent_res       = c("6" = 2L, "7" = 3L),
  parent_res_taxon = c("6" = 0L, "7" = 0L),
  parent_min_rows  = 50000,
  max_open         = EXPORT_MAX_OPEN,
  compression  = "zstd",
  overwrite    = FALSE,
  decades      = seq(1960L, 2020L, by = 10L),
  esn          = 50L,
  place_collections = NULL,
  memory_limit = NULL,
  threads      = NULL,
  verbose      = TRUE) {

  stopifnot(
    requireNamespace("DBI", quietly = TRUE),
    requireNamespace("jsonlite", quietly = TRUE),
    is.character(release), length(release) == 1L,
    grepl("^[A-Za-z0-9._-]+$", release),
    is.character(compression), length(compression) == 1L,
    grepl("^[A-Za-z0-9]+$", compression),
    all(as.integer(res_decade) %in% H3T_RES_IDX),
    is.numeric(parent_min_rows), length(parent_min_rows) == 1L,
    is.numeric(max_open), length(max_open) == 1L, max_open >= 1)
  check_pr <- function(pr) {
    if (is.null(pr) || !length(pr)) return(integer(0))
    stopifnot(!is.null(names(pr)), !anyNA(suppressWarnings(as.integer(names(pr)))),
              all(as.integer(pr) >= 0L), all(as.integer(pr) < as.integer(names(pr))))
    stats::setNames(as.integer(pr), as.integer(names(pr)))
  }
  parent_res       <- check_pr(parent_res)
  parent_res_taxon <- check_pr(parent_res_taxon)
  max_open         <- as.integer(max_open)
  t0  <- Sys.time()
  say <- function(...) if (verbose) message(...)
  res_decade <- sort(unique(as.integer(res_decade)))
  esn        <- as.integer(esn)

  out <- normalizePath(file.path(path.expand(dir_out), release), mustWork = FALSE)
  if (dir.exists(out)) {
    if (!overwrite)
      stop("output exists and overwrite = FALSE: ", out)
    unlink(out, recursive = TRUE)
  }
  dir.create(out, recursive = TRUE, showWarnings = FALSE)
  out <- normalizePath(out)  # resolve symlinks (e.g. /tmp) to match DuckDB paths

  # resource guards ----
  # one file per partition: DuckDB otherwise closes a partition's file once more
  # than partitioned_write_max_open_files (default 100) are open and starts a
  # data_1.parquet for it (the global taxon layer has ~11k partitions)
  DBI::dbExecute(con, "SET preserve_insertion_order = false;")
  DBI::dbExecute(con, "SET partitioned_write_max_open_files = 1000000;")
  on.exit({
    DBI::dbExecute(con, "RESET preserve_insertion_order;")
    DBI::dbExecute(con, "RESET partitioned_write_max_open_files;")
  }, add = TRUE)
  if (!is.null(memory_limit))
    DBI::dbExecute(con, glue::glue("SET memory_limit = '{memory_limit}';"))
  if (!is.null(threads))
    DBI::dbExecute(con, glue::glue("SET threads = {as.integer(threads)};"))

  has  <- function(t) .obis_has_table(con, t)
  if (!has("idx_h3")) stop("store has no idx_h3 table")
  q    <- function(x) gsub("'", "''", x)  # escape a path for a SQL literal
  cols <- "lower(printf('%x', cell_id)) AS h3, cell_id, n, sp, shannon, simpson, es"

  # one COPY ... PARTITION_BY per layer (or per res for the decade layers) ----
  copy <- function(sql, sub, parts) {
    d <- file.path(out, sub)
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
    DBI::dbExecute(con, glue::glue(
      "COPY ({sql}) TO '{q(d)}' (FORMAT PARQUET, COMPRESSION {compression}, ",
      "PARTITION_BY ({paste(parts, collapse = ', ')}), OVERWRITE_OR_IGNORE);"))
  }
  # the same, in batches of at most max_open partitions per COPY so the open
  # files stay under the OS limit: `groups` lists the partitions (one column
  # per entry of `parts`), `sql` must select those columns
  copy_batched <- function(sql, sub, parts, groups) {
    if (!nrow(groups)) return(0)
    lits  <- lapply(parts, function(p) {
      v <- groups[[p]]
      if (is.character(v)) .h3t_sql_quote(v) else as.character(as.integer(v))
    })
    tuple <- do.call(paste, c(lits, sep = ", "))
    batch <- (seq_len(nrow(groups)) - 1L) %/% max_open
    rows  <- 0
    for (b in unique(batch)) {
      keys <- paste0("(", tuple[batch == b], ")", collapse = ", ")
      rows <- rows + copy(glue::glue(
        "SELECT * FROM ({sql}) _s
         SEMI JOIN (VALUES {keys}) _v({paste(parts, collapse = ', ')})
         USING ({paste(parts, collapse = ', ')})"), sub, parts)
    }
    rows
  }
  layers <- list()
  add_layer <- function(name, sub, parts, rows, pr_used = integer(0)) {
    l <- list(
      path       = sub,
      partitions = I(parts),
      template   = paste0(sub, "/", paste0(parts, "=<", parts, ">", collapse = "/"),
                          "/data_0.parquet"),
      rows       = rows)
    if (length(pr_used)) {
      l$parent_res      <- as.list(pr_used)
      l$template_parent <- sub("/data_0.parquet$", "/p=<parent>/data_0.parquet",
                               l$template)
    }
    layers[[name]] <<- l
  }

  # a precomputed layer (idx_h3, idx_h3_eov, idx_h3_taxon): whole files per
  # (keys, res), except the res in `pr` with more than parent_min_rows rows,
  # which go one file per parent cell (res=<r>/p=<parent>/) ----
  write_layer <- function(name, sub, from, keys, pr) {
    parts <- c(keys, "res")
    kc    <- paste0(keys, ", ", collapse = "")
    if (!length(keys)) kc <- ""
    grp <- DBI::dbGetQuery(con, glue::glue(
      "SELECT {kc}res::INTEGER AS res, COUNT(*)::DOUBLE AS n
       FROM {from} GROUP BY ALL ORDER BY ALL"))
    fine <- grp$res %in% as.integer(names(pr)) & grp$n > parent_min_rows
    rows <- copy_batched(glue::glue("SELECT {kc}res, {cols} FROM {from}"),
                         sub, parts, grp[!fine, parts, drop = FALSE])
    pr_used <- pr[as.character(sort(unique(grp$res[fine])))]
    if (any(fine)) {
      p_expr <- paste0("CASE res ", paste(sprintf(
        "WHEN %d THEN lower(printf('%%x', h3_cell_to_parent(cell_id, %d)))",
        as.integer(names(pr_used)), pr_used), collapse = " "), " END")
      src <- glue::glue(
        "SELECT {kc}res, {p_expr} AS p, {cols} FROM {from}
         WHERE res IN ({paste(names(pr_used), collapse = ', ')})")
      fg  <- grp[fine, parts, drop = FALSE]
      fk  <- paste0("(", do.call(paste, c(lapply(parts, function(p) {
        v <- fg[[p]]
        if (is.character(v)) .h3t_sql_quote(v) else as.character(as.integer(v))
      }), sep = ", ")), ")", collapse = ", ")
      pg  <- DBI::dbGetQuery(con, glue::glue(
        "SELECT DISTINCT {kc}res::INTEGER AS res, p FROM ({src}) _s
         SEMI JOIN (VALUES {fk}) _v({paste(parts, collapse = ', ')})
         USING ({paste(parts, collapse = ', ')})
         ORDER BY ALL"))
      say("  ", nrow(pg), " parent partitions for res ",
          paste(names(pr_used), collapse = ", "))
      rows <- rows + copy_batched(src, sub, c(parts, "p"), pg)
    }
    add_layer(name, sub, parts, rows, pr_used)
  }

  say("all: idx_h3 ...")
  write_layer("all", "all", "idx_h3", character(0), parent_res)

  if (has("idx_h3_eov")) {
    say("eov: idx_h3_eov ...")
    write_layer("eov", "eov", "idx_h3_eov", "eov", parent_res)
  } else say("skipping eov: no idx_h3_eov table")

  if (has("idx_h3_taxon")) {
    say("taxon: idx_h3_taxon ...")
    write_layer("taxon", "taxon", "idx_h3_taxon", c("rank", "taxon"), parent_res_taxon)
  } else say("skipping taxon: no idx_h3_taxon table")

  # decade layers: computed from occ_h3 with the store's indicator SQL ----
  dec_expr <- function(p = "") glue::glue("CAST(floor({p}date_year / 10) * 10 AS INTEGER)")
  dec_filt <- function(p = "") if (is.null(decades)) "" else glue::glue(
    " AND {dec_expr(p)} IN ({paste(as.integer(decades), collapse = ', ')})")
  has_eov  <- has("eov")
  rows_all <- 0
  rows_eov <- 0
  for (r in res_decade) {
    tier <- .obis_tier(r)  # coarsest occ_h3 tier at least as fine as r
    say("decade res ", r, " (occ_h3 tier ", tier, ") ...")
    src <- glue::glue("
      SELECT {dec_expr()} AS decade,
             CAST(h3_cell_to_parent(cell_id, {r}) AS BIGINT) AS cell_id,
             species, SUM(records) AS ni
      FROM occ_h3
      WHERE res = {tier} AND date_year IS NOT NULL{dec_filt()}
      GROUP BY 1, 2, 3")
    ind <- .h3t_indicators_sql(src, keys = "decade", esn = esn)
    rows_all <- rows_all + copy(glue::glue(
      "SELECT decade, {r}::UTINYINT AS res, {cols} FROM ({ind}) _d"),
      "decade/all", c("decade", "res"))

    if (has_eov) {
      src <- glue::glue("
        SELECT e.eov, {dec_expr('o.')} AS decade,
               CAST(h3_cell_to_parent(o.cell_id, {r}) AS BIGINT) AS cell_id,
               o.species, SUM(o.records) AS ni
        FROM occ_h3 o
        JOIN eov e ON o.aphiaid = e.taxonID
        WHERE o.res = {tier} AND o.date_year IS NOT NULL{dec_filt('o.')}
        GROUP BY 1, 2, 3, 4")
      ind <- .h3t_indicators_sql(src, keys = c("eov", "decade"), esn = esn)
      rows_eov <- rows_eov + copy(glue::glue(
        "SELECT eov, decade, {r}::UTINYINT AS res, {cols} FROM ({ind}) _d"),
        "decade/eov", c("eov", "decade", "res"))
    }
  }
  add_layer("decade_all", "decade/all", c("decade", "res"), rows_all)
  if (has_eov)
    add_layer("decade_eov", "decade/eov", c("eov", "decade", "res"), rows_eov)
  else say("skipping decade_eov: no eov table")

  # place layer: per-place pooled, area-weighted indicators, one file per collection ----
  if (length(place_collections)) {
    slugs <- names(place_collections)
    stopifnot(
      "place_collections must be named by collection slug" =
        !is.null(slugs) && all(grepl("^[A-Za-z0-9._-]+$", slugs)) && !anyDuplicated(slugs))
    dec_place <- decades
    if (is.null(dec_place))
      dec_place <- DBI::dbGetQuery(con, glue::glue(
        "SELECT DISTINCT {dec_expr()} AS d FROM occ_h3 WHERE date_year IS NOT NULL ORDER BY 1"))$d
    rows_place <- 0
    colls      <- list()
    for (slug in slugs) {
      say("place: ", slug, " ...")
      mem <- place_collections[[slug]]
      if (is.character(mem) && length(mem) == 1L && !grepl("\\.parquet$", mem) &&
          !mem %in% DBI::dbListTables(con))
        mem <- obis_place_membership(mem, res = 7L)
      pl <- obis_place_indicators(con, mem, esn = esn, res = 7L,
                                  decades = if (length(dec_place)) dec_place else FALSE,
                                  eov = has_eov)
      d  <- file.path(out, "place", paste0("coll=", slug))
      dir.create(d, recursive = TRUE, showWarnings = FALSE)
      vw <- "export_place"
      duckdb::duckdb_register(con, vw, pl)
      DBI::dbExecute(con, glue::glue("
        COPY (
          SELECT place_id::VARCHAR AS place_id, layer::VARCHAR AS layer, key::VARCHAR AS key,
                 decade::INTEGER AS decade, n::DOUBLE AS n, sp::INTEGER AS sp,
                 shannon::DOUBLE AS shannon, simpson::DOUBLE AS simpson, es::DOUBLE AS es,
                 cells::INTEGER AS cells, area::DOUBLE AS area
          FROM {vw} ORDER BY place_id, layer, key, decade NULLS FIRST
        ) TO '{q(file.path(d, 'data_0.parquet'))}' (FORMAT PARQUET, COMPRESSION {compression});"))
      duckdb::duckdb_unregister(con, vw)
      rows_place <- rows_place + nrow(pl)
      info <- if (is.list(mem) && !is.data.frame(mem)) mem$info else NULL
      colls[[slug]] <- list(
        source             = if (is.character(place_collections[[slug]]))
                               place_collections[[slug]][1] else NULL,
        res                = 7L,
        places             = length(unique(pl$place_id)),
        collection_version = info$collection_version,
        places_sha256      = info$places_sha256,
        membership_version = info$version)
    }
    add_layer("place", "place", "coll", rows_place)
    layers$place$collections <- colls
    layers$place$columns <- I(c("place_id", "layer", "key", "decade", "n", "sp", "shannon",
                                "simpson", "es", "cells", "area"))
    layers$place$note <- paste(
      "one row per place x layer (all | eov) x key ('' | EOV) x decade (NULL = all years):",
      "indicators of the place's species counts pooled over its res-7 member cells, each",
      "cell's records weighted by its share of area inside the place (gazetteer",
      "membership, shares >= 0.01), so n is fractional; true per-place indices, not means",
      "of hexagon values. sp counts every species with a weighted record; es is NULL",
      "where n < esn; cells = member cells with records, area = their summed share.")
  }

  # stats.parquet: value ranges for colour ramps, read back from the files ----
  say("stats ...")
  # explicit hive types, so a taxon or EOV name is never auto-cast to a number
  hive_type <- c(res = "INTEGER", decade = "INTEGER", eov = "VARCHAR",
                 rank = "VARCHAR", taxon = "VARCHAR")
  hive_type <- c(hive_type, p = "VARCHAR")
  rd <- function(sub, parts) glue::glue(
    "read_parquet('{q(file.path(out, sub))}{strrep('/*', length(parts))}/*.parquet', ",
    "hive_partitioning = true, hive_types = {{",
    "{paste(sprintf(\"'%s': '%s'\", parts, hive_type[parts]), collapse = ', ')}}})")
  # a layer's whole files, plus its parent partitions (one level deeper) if any
  has_files <- function(sub, depth) length(Sys.glob(file.path(
    out, sub, paste(rep("*", depth), collapse = "/"), "*.parquet"))) > 0
  rd_layer <- function(l, sel) {
    parts <- layers[[l]]$partitions
    src   <- character(0)
    if (has_files(layers[[l]]$path, length(parts)))
      src <- glue::glue("SELECT {sel} FROM {rd(layers[[l]]$path, parts)}")
    if (length(layers[[l]]$parent_res))
      src <- c(src, glue::glue("SELECT {sel} FROM {rd(layers[[l]]$path, c(parts, 'p'))}"))
    paste(src, collapse = "\nUNION ALL\n")
  }
  key_sql <- list(
    all        = "'' AS key, '' AS rank, NULL::INTEGER AS decade",
    eov        = "eov AS key, '' AS rank, NULL::INTEGER AS decade",
    taxon      = "taxon AS key, rank, NULL::INTEGER AS decade",
    decade_all = "'' AS key, '' AS rank, decade",
    decade_eov = "eov AS key, '' AS rank, decade")
  live     <- names(layers)[vapply(layers, function(l) l$rows > 0, logical(1))]
  # one query per layer and variable, collected in R and written once: a single UNPIVOT over every
  # layer held all values in quantile_cont() states at once (not spillable) and, with the family
  # rank, outgrew a 24 GiB VM (killed 2026-10-12); per (layer, variable) the largest input is the
  # taxon layer's one column
  stats <- list()
  # (the place layer has no res: not in stats)
  for (l in intersect(live, names(key_sql))) for (v in EXPORT_VARS) {
    src <- rd_layer(l, glue::glue("'{l}' AS layer, {key_sql[[l]]}, res, '{v}' AS variable, {v}::DOUBLE AS value"))
    stats[[length(stats) + 1L]] <- DBI::dbGetQuery(con, glue::glue("
      SELECT layer, key, rank, decade, res, variable,
        MIN(value)                 AS min,
        quantile_cont(value, 0.02) AS p02,
        quantile_cont(value, 0.50) AS p50,
        quantile_cont(value, 0.98) AS p98,
        MAX(value)                 AS max,
        COUNT(value)               AS n_cells
      FROM ({src}) GROUP BY ALL"))
  }
  f_stats <- file.path(out, "stats.parquet")
  duckdb::duckdb_register(con, "export_stats", do.call(rbind, stats))
  on.exit(try(duckdb::duckdb_unregister(con, "export_stats"), silent = TRUE), add = TRUE)
  DBI::dbExecute(con, glue::glue("
    COPY (
      SELECT layer, key, rank, decade::INTEGER AS decade, res::INTEGER AS res, variable,
             min, p02, p50, p98, max, n_cells::BIGINT AS n_cells
      FROM export_stats
      ORDER BY layer, key, rank, decade, res, variable
    ) TO '{q(f_stats)}' (FORMAT PARQUET, COMPRESSION {compression});"))
  duckdb::duckdb_unregister(con, "export_stats")

  # taxon_groups.parquet: what the app can offer, with paths ----
  say("taxon_groups ...")
  grp <- list()
  if ("taxon" %in% live) {
    g <- DBI::dbGetQuery(con, glue::glue(
      "SELECT 'taxon' AS kind, rank, taxon, taxon AS label,
              SUM(n)::DOUBLE AS n, COUNT(*)::INTEGER AS n_cells_res1
       FROM {rd('taxon', c('rank', 'taxon', 'res'))} WHERE res = 1 GROUP BY ALL ORDER BY rank, taxon"))
    # on-disk partition dirs, matched to their decoded taxon names
    dirs <- list.dirs(file.path(out, "taxon"), recursive = TRUE, full.names = FALSE)
    dirs <- dirs[grepl("^rank=[^/]+/taxon=[^/]+$", dirs)]
    key  <- paste(sub("^rank=([^/]+)/.*", "\\1", dirs),
                  vapply(sub(".*/taxon=", "", dirs), utils::URLdecode, character(1)),
                  sep = "\r")
    g$path <- paste0("taxon/", dirs[match(paste(g$rank, g$taxon, sep = "\r"), key)])
    grp$taxon <- g
  }
  if ("eov" %in% live) {
    g <- DBI::dbGetQuery(con, glue::glue(
      "SELECT 'eov' AS kind, 'eov' AS rank, eov AS taxon,
              SUM(n)::DOUBLE AS n, COUNT(*)::INTEGER AS n_cells_res1
       FROM {rd('eov', c('eov', 'res'))} WHERE res = 1 GROUP BY ALL ORDER BY eov"))
    g$label <- unname(obis_eov_label(g$taxon))
    g$path  <- paste0("eov/eov=", g$taxon)
    grp$eov <- g[, c("kind", "rank", "taxon", "label", "n", "n_cells_res1", "path")]
  }
  f_groups <- file.path(out, "taxon_groups.parquet")
  if (length(grp)) {
    g <- do.call(rbind, unname(grp))
    g$url_path <- gsub("%", "%25", g$path, fixed = TRUE)
    duckdb::duckdb_register(con, "export_taxon_groups", g)
    on.exit(duckdb::duckdb_unregister(con, "export_taxon_groups"), add = TRUE)
    DBI::dbExecute(con, glue::glue(
      "COPY (SELECT * FROM export_taxon_groups) TO '{q(f_groups)}' ",
      "(FORMAT PARQUET, COMPRESSION {compression});"))
  } else {
    DBI::dbExecute(con, glue::glue(
      "COPY (SELECT NULL::VARCHAR AS kind, NULL::VARCHAR AS rank, NULL::VARCHAR AS taxon,
                    NULL::VARCHAR AS label, NULL::DOUBLE AS n, NULL::INTEGER AS n_cells_res1,
                    NULL::VARCHAR AS path, NULL::VARCHAR AS url_path WHERE false)
       TO '{q(f_groups)}' (FORMAT PARQUET, COMPRESSION {compression});"))
  }

  # file manifest + release.json ----
  files <- sort(list.files(out, pattern = "\\.parquet$", recursive = TRUE))
  meta  <- DBI::dbGetQuery(con, glue::glue(
    "SELECT file_name, num_rows FROM parquet_file_metadata('{q(out)}/**/*.parquet')
     UNION ALL
     SELECT file_name, num_rows FROM parquet_file_metadata('{q(out)}/*.parquet')"))
  meta$rel <- substring(normalizePath(meta$file_name), nchar(out) + 2L)
  manifest <- data.frame(
    path     = files,
    url_path = gsub("%", "%25", files, fixed = TRUE),
    rows     = as.numeric(meta$num_rows[match(files, meta$rel)]),
    bytes    = as.numeric(file.size(file.path(out, files))),
    stringsAsFactors = FALSE)
  manifest$parent <- ifelse(grepl("/p=[0-9a-f]+/", files),
                            sub(".*/p=([0-9a-f]+)/.*", "\\1", files), NA_character_)

  manifest$layer <- "meta"  # stats.parquet, taxon_groups.parquet
  for (l in names(layers))
    manifest$layer[startsWith(manifest$path, paste0(layers[[l]]$path, "/"))] <- l
  f_files <- file.path(out, "files.parquet")
  duckdb::duckdb_register(con, "export_files", manifest)
  on.exit(duckdb::duckdb_unregister(con, "export_files"), add = TRUE)
  DBI::dbExecute(con, glue::glue(
    "COPY (SELECT layer, path, url_path, rows::BIGINT AS rows, bytes::BIGINT AS bytes,
                  parent::VARCHAR AS parent
           FROM export_files ORDER BY path)
     TO '{q(f_files)}' (FORMAT PARQUET, COMPRESSION {compression});"))

  store <- tryCatch(DBI::dbGetInfo(con)$dbname, error = function(e) NA_character_)
  snap  <- .obis_snapshot(release)
  for (l in names(layers)) {
    lf <- manifest[startsWith(manifest$path, paste0(layers[[l]]$path, "/")), ]
    layers[[l]]$rows  <- sum(lf$rows)
    layers[[l]]$files <- nrow(lf)
    layers[[l]]$bytes <- sum(lf$bytes)
  }
  info <- list(
    release                = release,
    # the OBIS data date: the newest object of s3://obis-open-data/occurrence/ the store was built
    # from (OBIS_DATA_DATE, set by refresh_obis_h3.sh), else the date in the release tag
    obis_snapshot          = snap,
    store                  = basename(store),
    obisindicators_version = .obisindicators_version(),
    # the WoRMS (ChecklistBank) version the store's taxonomy came from, when the refresh knows it
    worms_version          = Sys.getenv("OBIS_WORMS_VERSION"),
    duckdb_version         = DBI::dbGetQuery(con, "SELECT version() AS v")$v,
    built_at               = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    esn                    = esn,
    res                    = sort(DBI::dbGetQuery(con, "SELECT DISTINCT res FROM idx_h3")$res),
    res_decade             = I(res_decade),
    decades                = if (is.null(decades)) "all" else I(as.integer(decades)),
    compression            = compression,
    layers                 = layers,
    columns                = EXPORT_COLUMNS,
    stats = list(
      file    = "stats.parquet",
      columns = c("layer", "key", "rank", "decade", "res", "variable",
                  "min", "p02", "p50", "p98", "max", "n_cells"),
      note    = "one row per layer x key x decade x res x variable; n_cells counts cells with a non-NULL value (0 when all are NULL, e.g. es where every n < 50)"),
    taxon_groups = list(
      file    = "taxon_groups.parquet",
      columns = c("kind", "rank", "taxon", "label", "n", "n_cells_res1", "path", "url_path")),
    encoding = paste(
      "partition values are percent-encoded on disk by DuckDB (space = %20);",
      "fetch over HTTP with `url_path` (each % encoded as %25), or read with",
      "DuckDB hive_partitioning, which decodes them."),
    decade_note = paste(
      "decade = floor(date_year / 10) * 10; records with no year are excluded;",
      "indicators computed with the same SQL as idx_h3 / idx_h3_eov."),
    files = list(
      file    = "files.parquet",
      columns = c("layer", "path", "url_path", "rows", "bytes", "parent"),
      n_files = nrow(manifest) + 1L,
      note    = "manifest of every parquet file except itself (HTTP cannot glob)"),
    parents = list(
      parent_res       = as.list(parent_res),
      parent_res_taxon = as.list(parent_res_taxon),
      parent_min_rows  = parent_min_rows,
      note = paste(
        "a layer's resolutions listed in its `parent_res` are split one file per",
        "parent cell, <layer path>/.../res=<r>/p=<parent h3>/data_0.parquet, for",
        "every (layer key, res) with more than parent_min_rows rows (others stay",
        "whole); files.parquet `parent` is that parent cell (NULL for a whole",
        "file), and its H3 resolution is the parent resolution. A viewer loads",
        "the parents covering its viewport.")))
  if (!nzchar(info$worms_version)) info$worms_version <- NULL   # unknown: left out, not ""
  f_json <- file.path(out, "release.json")
  jsonlite::write_json(info, f_json, auto_unbox = TRUE, pretty = TRUE,
                       digits = NA, dataframe = "rows")

  # summary ----
  if (verbose) {
    mb <- function(b) sprintf("%.1f MB", b / 1e6)
    message("exported ", out, " in ",
            format(round(difftime(Sys.time(), t0, units = "mins"), 1)))
    for (l in names(layers))
      message(sprintf("  %-11s %12s rows %6d files %10s", l,
                      format(layers[[l]]$rows, big.mark = ","),
                      layers[[l]]$files, mb(layers[[l]]$bytes)))
    message(sprintf("  total       %6d files %10s", nrow(manifest) + 2L,
                    mb(sum(manifest$bytes) + file.size(f_json) + file.size(f_files))))
  }
  invisible(c(f_json, f_files, file.path(out, manifest$path)))
}

# release.json's obis_snapshot: the OBIS data date when known (the newest object of
# s3://obis-open-data/occurrence/, as refresh_obis_h3.sh reads it off the synced files), else the
# date in a vYYYYMMDD release tag, else the tag itself
.obis_snapshot <- function(release, data_date = Sys.getenv("OBIS_DATA_DATE")) {
  if (grepl("^\\d{4}-\\d{2}-\\d{2}$", data_date)) return(data_date)
  if (grepl("^v?\\d{8}$", release)) {
    d <- sub("^v", "", release)
    return(paste(substr(d, 1, 4), substr(d, 5, 6), substr(d, 7, 8), sep = "-"))
  }
  release
}

# the obisindicators version for release.json: the checkout's DESCRIPTION when the code was sourced
# from one (OBIS_PKG_ROOT, as the monthly refresh does inside its image, which does not install the
# package), else the installed package's; NA when neither is available
.obisindicators_version <- function(pkg_root = Sys.getenv("OBIS_PKG_ROOT")) {
  f <- file.path(pkg_root, "DESCRIPTION")
  if (nzchar(pkg_root) && file.exists(f)) {
    d <- read.dcf(f, fields = c("Package", "Version"))
    if (identical(unname(d[1, "Package"]), "obisindicators")) return(unname(d[1, "Version"]))
  }
  tryCatch(as.character(utils::packageVersion("obisindicators")), error = function(e) NA_character_)
}
