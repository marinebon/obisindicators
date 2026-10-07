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

#' Export an obis_h3 store to hive-partitioned Parquet
#'
#' Writes the indicator layers of a store built by [build_obis_h3_duckdb()] to
#' a directory of hive-partitioned Parquet files that a static web app can read
#' directly with DuckDB-WASM (one small file per map layer and H3 resolution):
#'
#' ```
#' <dir_out>/<release>/
#'   release.json                              build metadata, row counts, layout, columns, file manifest
#'   all/res=<1..7>/data_0.parquet             idx_h3 (all taxa, all years)
#'   eov/eov=<eov>/res=<r>/data_0.parquet      idx_h3_eov
#'   taxon/rank=<rank>/taxon=<taxon>/res=<r>/  idx_h3_taxon (phylum / class / order)
#'   decade/all/decade=<yyy0>/res=<r>/         per decade, all taxa  (res in res_decade)
#'   decade/eov/eov=<eov>/decade=<yyy0>/res=<r>/  per decade and EOV (res in res_decade)
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
#' `stats.parquet` has one row per (`layer`, `key`, `decade`, `res`,
#' `variable`) with `min`, `p02`, `p50`, `p98`, `max` and `n_cells` (cells with
#' a non-NULL value; a variable NULL everywhere in a partition gets a row with
#' NULL ranges and `n_cells` 0), for colour ramps. `key` is the EOV or taxon
#' name ('' for the all-taxa layers), `rank` the taxon rank ('' otherwise),
#' `decade` NA outside the decade layers.
#'
#' @param con connection from [obis_store_connect()] (read-only is fine).
#' @param dir_out output directory; files go under `dir_out/release/`.
#' @param release release tag, e.g. `"v20260728"` (the OBIS snapshot date the
#'   store was built from); recorded in `release.json`.
#' @param res_decade H3 resolutions for the decade layers (default 1-5).
#' @param compression Parquet compression codec (default `"zstd"`).
#' @param overwrite replace an existing `dir_out/release/` (default FALSE: stop).
#' @param decades decades (first year) to export in the decade layers; default
#'   1960-2020. NULL exports every decade present.
#' @param esn expected sample size for ES(n) in the decade layers; default 50
#'   (as in the store).
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
  res_decade   = 1:5,
  compression  = "zstd",
  overwrite    = FALSE,
  decades      = seq(1960L, 2020L, by = 10L),
  esn          = 50L,
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
    all(as.integer(res_decade) %in% H3T_RES_IDX))
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
  layers <- list()
  add_layer <- function(name, sub, parts, rows) {
    layers[[name]] <<- list(
      path       = sub,
      partitions = I(parts),
      template   = paste0(sub, "/", paste0(parts, "=<", parts, ">", collapse = "/"),
                          "/data_0.parquet"),
      rows       = rows)
  }

  say("all: idx_h3 ...")
  rows <- copy(glue::glue("SELECT res, {cols} FROM idx_h3"), "all", "res")
  add_layer("all", "all", "res", rows)

  if (has("idx_h3_eov")) {
    say("eov: idx_h3_eov ...")
    rows <- copy(glue::glue("SELECT eov, res, {cols} FROM idx_h3_eov"),
                 "eov", c("eov", "res"))
    add_layer("eov", "eov", c("eov", "res"), rows)
  } else say("skipping eov: no idx_h3_eov table")

  if (has("idx_h3_taxon")) {
    say("taxon: idx_h3_taxon ...")
    rows <- copy(glue::glue("SELECT rank, taxon, res, {cols} FROM idx_h3_taxon"),
                 "taxon", c("rank", "taxon", "res"))
    add_layer("taxon", "taxon", c("rank", "taxon", "res"), rows)
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

  # stats.parquet: value ranges for colour ramps, read back from the files ----
  say("stats ...")
  # explicit hive types, so a taxon or EOV name is never auto-cast to a number
  hive_type <- c(res = "INTEGER", decade = "INTEGER", eov = "VARCHAR",
                 rank = "VARCHAR", taxon = "VARCHAR")
  rd <- function(sub, parts) glue::glue(
    "read_parquet('{q(file.path(out, sub))}{strrep('/*', length(parts))}/*.parquet', ",
    "hive_partitioning = true, hive_types = {{",
    "{paste(sprintf(\"'%s': '%s'\", parts, hive_type[parts]), collapse = ', ')}}})")
  key_sql <- list(
    all        = "'' AS key, '' AS rank, NULL::INTEGER AS decade",
    eov        = "eov AS key, '' AS rank, NULL::INTEGER AS decade",
    taxon      = "taxon AS key, rank, NULL::INTEGER AS decade",
    decade_all = "'' AS key, '' AS rank, decade",
    decade_eov = "eov AS key, '' AS rank, decade")
  parts_of <- lapply(layers, `[[`, "partitions")
  live     <- names(layers)[vapply(layers, function(l) l$rows > 0, logical(1))]
  vals     <- paste(sprintf("%s::DOUBLE AS %s", EXPORT_VARS, EXPORT_VARS), collapse = ", ")
  union    <- paste(vapply(live, function(l) glue::glue(
    "SELECT '{l}' AS layer, {key_sql[[l]]}, res, {vals} ",
    "FROM {rd(layers[[l]]$path, parts_of[[l]])}"), character(1)),
    collapse = "\nUNION ALL\n")
  f_stats <- file.path(out, "stats.parquet")
  DBI::dbExecute(con, glue::glue("
    COPY (
      WITH d AS ({union}),
      u AS (SELECT * FROM d UNPIVOT INCLUDE NULLS
              (value FOR variable IN ({paste(EXPORT_VARS, collapse = ', ')})))
      SELECT layer, key, rank, decade, res, variable,
        MIN(value)                 AS min,
        quantile_cont(value, 0.02) AS p02,
        quantile_cont(value, 0.50) AS p50,
        quantile_cont(value, 0.98) AS p98,
        MAX(value)                 AS max,
        COUNT(value)               AS n_cells
      FROM u
      GROUP BY ALL
      ORDER BY layer, key, rank, decade, res, variable
    ) TO '{q(f_stats)}' (FORMAT PARQUET, COMPRESSION {compression});"))

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

  manifest$layer <- "meta"  # stats.parquet, taxon_groups.parquet
  for (l in names(layers))
    manifest$layer[startsWith(manifest$path, paste0(layers[[l]]$path, "/"))] <- l
  f_files <- file.path(out, "files.parquet")
  duckdb::duckdb_register(con, "export_files", manifest)
  on.exit(duckdb::duckdb_unregister(con, "export_files"), add = TRUE)
  DBI::dbExecute(con, glue::glue(
    "COPY (SELECT layer, path, url_path, rows::BIGINT AS rows, bytes::BIGINT AS bytes
           FROM export_files ORDER BY path)
     TO '{q(f_files)}' (FORMAT PARQUET, COMPRESSION {compression});"))

  store <- tryCatch(DBI::dbGetInfo(con)$dbname, error = function(e) NA_character_)
  snap  <- if (grepl("^v?\\d{8}$", release)) {
    d <- sub("^v", "", release)
    paste(substr(d, 1, 4), substr(d, 5, 6), substr(d, 7, 8), sep = "-")
  } else release
  for (l in names(layers)) {
    lf <- manifest[startsWith(manifest$path, paste0(layers[[l]]$path, "/")), ]
    layers[[l]]$rows  <- sum(lf$rows)
    layers[[l]]$files <- nrow(lf)
    layers[[l]]$bytes <- sum(lf$bytes)
  }
  info <- list(
    release                = release,
    obis_snapshot          = snap,
    store                  = basename(store),
    obisindicators_version = as.character(utils::packageVersion("obisindicators")),
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
      columns = c("layer", "path", "url_path", "rows", "bytes"),
      n_files = nrow(manifest) + 1L,
      note    = "manifest of every parquet file except itself (HTTP cannot glob)"))
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
