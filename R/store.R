# connect to, summarize, query and benchmark an obis_h3 DuckDB store from R.
# these are the analysis-side counterparts of the tile builders in R/h3t.R:
# the same SQL, executed at a fixed resolution and returned as a data frame
# keyed on the hex *string* (H3 BIGINT ids exceed R double precision).
# see the paper/ notebooks for how they compose into figures.

# H3 resolution table (average hexagon area and edge length), from
# https://h3geo.org/docs/core-library/restable ----
H3_RES_TABLE <- data.frame(
  res      = 0:10,
  area_km2 = c(4357449.416, 609788.442, 86801.780, 12393.435, 1770.348,
               252.904, 36.129, 5.161, 0.737, 0.105, 0.015),
  edge_km  = c(1281.256, 483.057, 182.513, 68.979, 26.072, 9.854, 3.725,
               1.406, 0.531, 0.201, 0.076))

#' H3 resolution table
#'
#' Average hexagon area (km²) and edge length (km) per H3 resolution, from the
#' [H3 resolution table](https://h3geo.org/docs/core-library/restable).
#'
#' @param res optional resolution(s) to subset to.
#' @return data frame with `res`, `area_km2`, `edge_km`.
#' @concept store
#' @export
#' @examples
#' h3_res_table(1:7)
h3_res_table <- function(res = NULL) {
  d <- H3_RES_TABLE
  if (!is.null(res)) d <- d[d$res %in% as.integer(res), , drop = FALSE]
  rownames(d) <- NULL
  d
}

#' Connect to an obis_h3 DuckDB store
#'
#' Opens a (by default read-only) DuckDB connection to a store produced by
#' [build_obis_h3_duckdb()] and loads the `h3` community extension, which every
#' query in this package needs (`h3_cell_to_parent`, `h3_h3_to_string`, ...).
#'
#' @param path path to the `.duckdb` file; defaults to the `OBIS_H3_DUCKDB`
#'   environment variable (set it once per machine, e.g. in `~/.Renviron`).
#' @param read_only open read-only (default TRUE; the analysis functions only
#'   read). Pass FALSE to bake layers (e.g. [obis_eov_bake()]).
#' @param install_h3 run `INSTALL h3 FROM community` before `LOAD h3` (needs
#'   network the first time; default TRUE).
#'
#' @return a `DBI` connection. Disconnect with
#'   `DBI::dbDisconnect(con, shutdown = TRUE)`.
#' @concept store
#' @export
obis_store_connect <- function(
  path       = Sys.getenv("OBIS_H3_DUCKDB"),
  read_only  = TRUE,
  install_h3 = TRUE) {

  stopifnot(requireNamespace("DBI", quietly = TRUE),
            requireNamespace("duckdb", quietly = TRUE))
  path <- path.expand(path)
  if (!nzchar(path) || !file.exists(path))
    stop("store not found: '", path,
         "'. Set OBIS_H3_DUCKDB or pass `path` (see paper/build_demo_store.R).")

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = path, read_only = read_only)
  if (install_h3)
    tryCatch(DBI::dbExecute(con, "INSTALL h3 FROM community;"),
             error = function(e) NULL)  # already installed / offline: LOAD decides
  DBI::dbExecute(con, "LOAD h3;")
  con
}

# does the store have this table? ----
.obis_has_table <- function(con, name) name %in% DBI::dbListTables(con)

# the occ_h3 resolution tier that serves a display resolution ----
.obis_tier <- function(res) {
  res <- as.integer(res)
  ifelse(res <= 3L, 3L, ifelse(res <= 5L, 5L, 7L))
}

#' Summarize an obis_h3 store (tables, rows, totals)
#'
#' The "Table 2" of a store: every table with its row count, plus the headline
#' totals a reader needs to size the data — records and species at the base
#' resolution, occupied cells per resolution, taxonomy rows, EOV membership,
#' and the file size.
#'
#' @param con connection from [obis_store_connect()].
#' @return a list with `tables` (table, rows), `totals` (metric, value) and
#'   `cells_by_res` (res, n_cells, area_km2).
#' @concept store
#' @export
obis_store_stats <- function(con) {
  stopifnot(requireNamespace("DBI", quietly = TRUE))
  tbls <- DBI::dbListTables(con)

  rows <- vapply(tbls, function(t)
    as.numeric(DBI::dbGetQuery(
      con, glue::glue('SELECT COUNT(*) AS n FROM "{t}"'))$n), numeric(1))
  tables <- data.frame(table = tbls, rows = unname(rows), stringsAsFactors = FALSE)

  totals <- list()
  if ("occ_h3" %in% tbls) {
    b <- DBI::dbGetQuery(con, glue::glue("
      SELECT SUM(records) AS records,
             COUNT(DISTINCT species) AS species,
             COUNT(DISTINCT aphiaid) AS aphiaids,
             COUNT(DISTINCT cell_id) AS cells_base,
             MIN(date_year) AS year_min, MAX(date_year) AS year_max
      FROM occ_h3 WHERE res = {H3T_RES_BASE}"))
    totals$records    <- b$records
    totals$species    <- b$species
    totals$aphiaids   <- b$aphiaids
    totals$cells_base <- b$cells_base
    totals$year_min   <- b$year_min
    totals$year_max   <- b$year_max
  }
  if ("taxon" %in% tbls)
    totals$taxon_rows <- rows[["taxon"]]
  if ("eov" %in% tbls)
    totals$eov_members <- rows[["eov"]]
  sz <- tryCatch(DBI::dbGetQuery(con, "PRAGMA database_size"),
                 error = function(e) NULL)
  if (!is.null(sz) && "database_size" %in% names(sz))
    totals$database_size <- sz$database_size[1]

  totals_df <- data.frame(
    metric = names(totals),
    value  = vapply(totals, function(v) as.character(v), character(1)),
    stringsAsFactors = FALSE)
  rownames(totals_df) <- NULL

  cells_by_res <- NULL
  if ("idx_h3" %in% tbls) {
    cells_by_res <- DBI::dbGetQuery(con, "
      SELECT res, COUNT(*) AS n_cells, SUM(n) AS records
      FROM idx_h3 GROUP BY res ORDER BY res")
    cells_by_res <- merge(cells_by_res, H3_RES_TABLE, by = "res", all.x = TRUE)
  }

  list(tables = tables, totals = totals_df, cells_by_res = cells_by_res)
}

#' Run a tile SQL at a fixed H3 resolution
#'
#' Executes the read-only `SELECT cell_id, value, n` produced by
#' [obis_h3t_sql()], [obis_eov_sql()] or [obis_spue_sql()] with the `{{res}}`
#' placeholder bound to one resolution, and returns the cells keyed on the hex
#' string (H3 `BIGINT` ids exceed R's double precision, so never carry them as
#' numbers in R).
#'
#' @param con connection from [obis_store_connect()].
#' @param sql tile SQL containing `{{res}}` (or already resolved).
#' @param res H3 resolution to bind (1-7).
#' @param res_placeholder the placeholder string in `sql`.
#'
#' @return data frame with `cell` (hex string), `value`, `n`.
#' @concept store
#' @export
obis_h3t_query <- function(con, sql, res, res_placeholder = "{{res}}") {
  stopifnot(requireNamespace("DBI", quietly = TRUE))
  res <- as.integer(res)
  stopifnot(length(res) == 1L, res >= 0L, res <= 15L)
  q <- gsub(res_placeholder, as.character(res), sql, fixed = TRUE)
  DBI::dbGetQuery(con, glue::glue(
    "SELECT h3_h3_to_string(cell_id) AS cell, value, n FROM ({q}) _t"))
}

# one tile-SQL builder for any of the package's filters, at a literal res.
# dispatches to obis_eov_sql() when `eov` is given (which itself routes to
# idx_h3_eov or the live subtree), else obis_h3t_sql() (idx_h3 / idx_h3_taxon
# / live). `live` forces the live path (useful to test precomputed == live).
.obis_indicator_sql <- function(
  indicator, res, eov = NULL, aphiaid = NULL, taxon = NULL, years = NULL,
  esn = 50L, live = NULL) {
  r <- as.character(as.integer(res))
  if (!is.null(eov)) {
    if (!is.null(aphiaid) || !is.null(taxon))
      stop("give one of `eov`, `aphiaid` or `taxon`")
    return(obis_eov_sql(
      eov, indicator = indicator, years = years, esn = esn,
      res_max = 7L, res_placeholder = r, live = live))
  }
  if (isTRUE(live) && is.null(aphiaid) && is.null(taxon) && is.null(years))
    # the all-taxa live path: an open year range forces obis_h3t_sql() off idx_h3
    years <- c(NA, NA)
  obis_h3t_sql(
    indicator = indicator, taxon = taxon, aphiaid = aphiaid, years = years,
    esn = esn, res_max = 7L, res_placeholder = r)
}

#' Per-cell indicators for a filter at one resolution
#'
#' Returns every indicator the tile builders expose — record count `n`,
#' richness `sp`, `shannon`, ES(n) `es` — for one filter (all taxa, an EOV, an
#' AphiaID subtree, or DwC rank values) at one H3 resolution, as a data frame
#' keyed on the hex string. Reads a precomputed layer (`idx_h3`, `idx_h3_eov`)
#' in one query when the filter allows, otherwise runs the live tile SQL once
#' per indicator and joins. No new indicator math lives here: everything comes
#' from [obis_h3t_sql()] / [obis_eov_sql()], which are pinned to
#' [calc_indicators()] by the package tests.
#'
#' @param con connection from [obis_store_connect()].
#' @param res H3 resolution (1-7).
#' @param eov optional EOV name (one); see [obis_eov_seeds()].
#' @param aphiaid optional WoRMS AphiaID(s) — the subtree filter.
#' @param taxon optional named list of DwC rank values; see [obis_h3t_sql()].
#' @param years optional `c(min, max)` year range.
#' @param esn expected sample size for ES(n); default 50.
#' @param live force the live `occ_h3` path even when a precomputed layer
#'   exists (default NULL = use the precomputed layer when possible).
#'
#' @return data frame with `cell`, `n`, `sp`, `shannon`, `es` (and `simpson`
#'   when read from a precomputed layer).
#' @concept analyze
#' @export
obis_cell_indicators <- function(
  con, res, eov = NULL, aphiaid = NULL, taxon = NULL, years = NULL,
  esn = 50L, live = NULL) {

  stopifnot(requireNamespace("DBI", quietly = TRUE))
  res <- as.integer(res)
  if (!is.null(eov) && (!is.null(aphiaid) || !is.null(taxon)))
    stop("give one of `eov`, `aphiaid` or `taxon`")
  no_filter <- is.null(eov) && is.null(aphiaid) && is.null(taxon) && is.null(years)

  # fast paths: one precomputed row per cell carries every indicator
  if (!isTRUE(live) && no_filter && .obis_has_table(con, "idx_h3"))
    return(DBI::dbGetQuery(con, glue::glue(
      "SELECT h3_h3_to_string(cell_id) AS cell, n, sp, shannon, simpson, es
       FROM idx_h3 WHERE res = {res}")))
  if (!isTRUE(live) && !is.null(eov) && length(eov) == 1L && is.null(years) &&
      .obis_has_table(con, "idx_h3_eov")) {
    k <- .obis_eov_names(eov)
    return(DBI::dbGetQuery(con, glue::glue(
      "SELECT h3_h3_to_string(cell_id) AS cell, n, sp, shannon, simpson, es
       FROM idx_h3_eov WHERE eov = '{k}' AND res = {res}")))
  }

  # live: run the served SQL per indicator and join on the hex string
  get <- function(ind) obis_h3t_query(con, .obis_indicator_sql(
    ind, res, eov = eov, aphiaid = aphiaid, taxon = taxon, years = years,
    esn = esn, live = TRUE), res)
  es <- get("es")      # value = es, n = records
  sp <- get("sp")
  sh <- get("shannon")
  out <- es |>
    dplyr::select(cell, es = value, n) |>
    dplyr::left_join(dplyr::select(sp, cell, sp = value), by = "cell") |>
    dplyr::left_join(dplyr::select(sh, cell, shannon = value), by = "cell") |>
    dplyr::select(cell, n, sp, shannon, es)
  as.data.frame(out)
}

#' Benchmark queries against a store
#'
#' Times each SQL statement: the first (cold) run and the median of `reps`
#' further (warm) runs, plus the number of rows returned. Use with
#' [obis_bench_queries()] for the paper's default set, or any named character
#' vector of SQL.
#'
#' @param con connection from [obis_store_connect()].
#' @param queries named character vector of SQL statements (no `{{res}}`
#'   placeholders — bind them first, e.g. via `res_placeholder`).
#' @param reps number of warm repetitions after the cold run (default 3).
#'
#' @return data frame with `label`, `rows`, `cold_s`, `warm_s` (median).
#' @concept store
#' @export
obis_bench <- function(con, queries, reps = 3L) {
  stopifnot(requireNamespace("DBI", quietly = TRUE),
            is.character(queries), !is.null(names(queries)))
  run <- function(q) {
    t0 <- proc.time()[["elapsed"]]
    n  <- nrow(DBI::dbGetQuery(con, q))
    list(s = proc.time()[["elapsed"]] - t0, rows = n)
  }
  out <- lapply(names(queries), function(lbl) {
    cold <- run(queries[[lbl]])
    warm <- vapply(seq_len(max(0L, as.integer(reps))),
                   function(i) run(queries[[lbl]])$s, numeric(1))
    data.frame(
      label  = lbl,
      rows   = cold$rows,
      cold_s = cold$s,
      warm_s = if (length(warm)) stats::median(warm) else NA_real_,
      stringsAsFactors = FALSE)
  })
  do.call(rbind, out)
}

#' The paper's default benchmark query set
#'
#' Builds the SQL for the four serving paths at each resolution: the
#' precomputed all-taxa layer (`idx_h3`), the precomputed EOV layer
#' (`idx_h3_eov`), the live EOV subtree over `occ_h3`, and the SPUE effort
#' proxy (two recursive subtrees).
#'
#' @param res resolutions to benchmark (default 3, 5, 7).
#' @param eov EOV for the precomputed/live comparison (default `"fish"`).
#' @param num_aphiaid,den_aphiaid SPUE target/effort AphiaIDs (default humpback
#'   whale 137092 over Cetacea 2688).
#' @param esn expected sample size for ES(n).
#'
#' @return named character vector of SQL, ready for [obis_bench()].
#' @concept store
#' @export
obis_bench_queries <- function(
  res = c(3L, 5L, 7L), eov = "fish", num_aphiaid = 137092L,
  den_aphiaid = 2688L, esn = 50L) {
  q <- character(0)
  for (r in as.integer(res)) {
    rr <- as.character(r)
    q[[glue::glue("idx_h3 all-taxa ES50 res {r}")]] <-
      obis_h3t_sql("es", esn = esn, res_placeholder = rr)
    q[[glue::glue("idx_h3_eov {eov} ES50 res {r}")]] <-
      obis_eov_sql(eov, "es", esn = esn, res_placeholder = rr)
    q[[glue::glue("live subtree {eov} ES50 res {r}")]] <-
      obis_eov_sql(eov, "es", esn = esn, res_placeholder = rr, live = TRUE)
    q[[glue::glue("SPUE {num_aphiaid}/{den_aphiaid} res {r}")]] <-
      obis_spue_sql(num_aphiaid, den_aphiaid, res_placeholder = rr)
  }
  q
}
