# roll hexagon-level records up to management places (sanctuaries, EEZs,
# LMEs, ...): the "place hierarchy" of Best et al. — small cells summarize to
# fit-for-purpose polygons. indicators are computed by calc_indicators() on the
# species totals per place, so the math is the package reference. paper Fig. 6.

#' H3 cells covering each place polygon
#'
#' @param places an `sf` of polygons (lon/lat, EPSG:4326).
#' @param name_col column naming each place; default the first non-geometry
#'   column.
#' @param res H3 resolution to fill at (default 7, the store's base).
#'
#' @return data frame with `place`, `cell` (hex string).
#' @concept analyze
#' @export
place_cells <- function(places, name_col = NULL, res = 7L) {
  stopifnot(inherits(places, "sf"))
  if (is.null(name_col))
    name_col <- setdiff(names(places), attr(places, "sf_column"))[1]
  places <- sf::st_transform(places, 4326)
  geom   <- sf::st_geometry(places)
  rows <- lapply(seq_len(nrow(places)), function(i) {
    ids <- h3::polyfill(geom[i], res = as.integer(res))
    if (!length(ids)) return(NULL)
    data.frame(place = as.character(places[[name_col]][i]), cell = ids,
               stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, rows)
  if (is.null(out))
    out <- data.frame(place = character(0), cell = character(0))
  rownames(out) <- NULL
  out
}

#' Indicators rolled up from H3 cells to places
#'
#' Fills each polygon with H3 cells at `res`, sums species records over those
#' cells from `occ_h3` (optionally restricted to an EOV, an AphiaID subtree,
#' DwC rank values and/or a year range), and computes the indicators per place
#' with [calc_indicators()]. Also reports the number of cells filled and the
#' number with any record, so sparse places are visible.
#'
#' @inheritParams obis_cell_indicators
#' @inheritParams place_cells
#'
#' @return data frame with `place`, `n_cells`, `n_cells_occupied`, and the
#'   [calc_indicators()] columns (`n`, `sp`, `shannon`, `simpson`, `es`,
#'   `hill_1`, `hill_2`, `hill_inf`).
#' @concept analyze
#' @export
calc_place_indicators <- function(
  con, places, name_col = NULL, res = 7L, eov = NULL, aphiaid = NULL,
  taxon = NULL, years = NULL, esn = 50L) {

  stopifnot(requireNamespace("DBI", quietly = TRUE),
            requireNamespace("duckdb", quietly = TRUE))
  res  <- as.integer(res)
  pc   <- place_cells(places, name_col, res)
  if (!nrow(pc)) stop("no H3 cells at res ", res, " fall inside `places`")

  # the cell list as a view DuckDB can join (read-only connections allow this)
  vw <- paste0("_place_cells_", as.integer(stats::runif(1, 1e6, 1e7)))
  duckdb::duckdb_register(con, vw, pc)
  on.exit(duckdb::duckdb_unregister(con, vw), add = TRUE)

  tier <- .obis_tier(res)
  filt <- character(0)
  with_kw <- ""
  if (!is.null(eov)) {
    if (!is.null(aphiaid)) stop("give one of `eov` or `aphiaid`")
    aphiaid <- obis_eov_aphiaid(eov)
  }
  if (!is.null(aphiaid)) {
    with_kw <- paste0("WITH RECURSIVE ", .h3t_taxon_tree_cte(aphiaid))
    filt <- c(filt, "o.aphiaid IN (SELECT taxonID FROM taxon_tree)")
  }
  # "AND ..." or "" — rank/year columns only exist on occ_h3, so no aliasing needed
  wc <- .h3t_where_clause(taxon, years)
  where <- paste(c(glue::glue("o.res = {tier}"), filt), collapse = "\n        AND ")

  long <- DBI::dbGetQuery(con, glue::glue("
    {with_kw}
    SELECT p.place AS cell, o.species, SUM(o.records) AS records
    FROM occ_h3 o
    JOIN {vw} p
      ON CAST(h3_cell_to_parent(o.cell_id, {res}) AS BIGINT) = h3_string_to_h3(p.cell)
    WHERE {where}
        {wc}
    GROUP BY 1, 2"))

  occ_cells <- DBI::dbGetQuery(con, glue::glue("
    {with_kw}
    SELECT p.place, COUNT(DISTINCT p.cell) AS n_cells_occupied
    FROM occ_h3 o
    JOIN {vw} p
      ON CAST(h3_cell_to_parent(o.cell_id, {res}) AS BIGINT) = h3_string_to_h3(p.cell)
    WHERE {where}
        {wc}
    GROUP BY 1"))

  n_cells <- pc |> dplyr::count(place, name = "n_cells")
  ind <- if (nrow(long)) calc_indicators(long, esn = esn) else
    data.frame(cell = character(0))
  out <- n_cells |>
    dplyr::left_join(occ_cells, by = "place") |>
    dplyr::left_join(ind, by = c("place" = "cell")) |>
    dplyr::mutate(n_cells_occupied = dplyr::coalesce(n_cells_occupied, 0L))
  as.data.frame(out)
}

# per-place pooled indicators from a gazetteer's H3 membership (area-weighted) ----

# where the Ocean Metrics gazetteer publishes each collection's H3 membership
PLACE_GAZETTEER_BASE <- "https://s3.us-east-1.amazonaws.com/oceanmetrics.io-public/gazetteer"

#' H3 membership files of a gazetteer collection
#'
#' Resolves a polygon collection of the Ocean Metrics gazetteer to the
#' `membership.parquet` files of one H3 resolution, read off the collection's
#' `h3/membership.json`. Each file has the columns `place_id` (VARCHAR), `h3`
#' (lowercase hex string) and `share` (the fraction of the cell's area inside
#' the place; the gazetteer keeps a cell when it is at least `min_share`, 1%,
#' or when the cell holds at least 1% of the place). A cell may belong to
#' several places. Resolutions 1-5 are one file each, the finer ones one file
#' per parent cell.
#'
#' @param collection the collection directory or URL (e.g.
#'   `<base>/gazetteer/<slug>`), its `h3/` directory, or the
#'   `membership.json` itself (local path or URL). A bare slug (no `/`) is
#'   taken under `base`.
#' @param res H3 resolution of the membership to use (default 7, the store's
#'   base resolution).
#' @param base the gazetteer root for a bare slug.
#'
#' @return a list with `files` (paths or URLs of the membership parquet files
#'   at `res`), `res`, and `info` (the parsed `membership.json`).
#' @concept analyze
#' @export
#' @examples
#' \dontrun{
#' obis_place_membership("noaa_aoa_socal")$files
#' }
obis_place_membership <- function(collection, res = 7L, base = PLACE_GAZETTEER_BASE) {
  stopifnot(requireNamespace("jsonlite", quietly = TRUE),
            is.character(collection), length(collection) == 1L, nzchar(collection))
  res   <- as.integer(res)
  is_url <- grepl("^[a-z][a-z0-9+.-]*://", collection)
  x     <- sub("/+$", "", collection)
  if (!is_url && !grepl("/", x) && !file.exists(x))
    x <- paste0(sub("/+$", "", base), "/", x)
  is_url <- grepl("^[a-z][a-z0-9+.-]*://", x)
  json <- if (grepl("\\.json$", x)) x else if (basename(x) == "h3")
    paste0(x, "/membership.json") else paste0(x, "/h3/membership.json")
  if (!is_url) json <- path.expand(json)
  if (!is_url && !file.exists(json)) stop("no membership.json at ", json)
  info <- jsonlite::read_json(json)
  # file paths in membership.json are relative to the collection dir (h3/...)
  h3_dir <- dirname(json)
  coll   <- if (basename(h3_dir) == "h3") dirname(h3_dir) else h3_dir
  f_res  <- vapply(info$files, function(f) as.integer(f$res), integer(1))
  if (!res %in% f_res)
    stop("membership has no res ", res, " (has ", paste(sort(unique(f_res)), collapse = ", "), ")")
  paths <- vapply(info$files[f_res == res], function(f) f$path, character(1))
  list(files = paste0(coll, "/", paths), res = res, info = info)
}

#' Indicators per place, pooled from area-weighted H3 cells
#'
#' Computes the indicators of each place of a polygon collection from the
#' species records of the H3 cells that intersect it, weighting every cell's
#' records by the cell's `share` of area inside the place: for each place and
#' species, `ni = sum(records * share)` over the member cells, and the
#' indicators are those of [calc_indicators()] on those pooled counts (same
#' SQL as the store's precomputed layers). The layers are `all` (all taxa) and
#' `eov` (one row per EOV, by the store's `eov` membership), each for all
#' years (`decade` NA) and per decade (`decade = floor(date_year / 10) * 10`,
#' records without a year left out), as in [obis_h3_export_parquet()].
#'
#' **Science caveat.** These are true per-place indices computed from pooled,
#' area-weighted species counts, not means of hexagon values: a place's
#' richness or ES(50) is that of the place as one sample. Because of the
#' weighting, `n` and the per-species counts are fractional (a cell half inside
#' the place contributes half its records). Richness `sp` counts every species
#' with any weighted record inside the place, so a species seen only in a cell
#' that barely touches the place still counts once. ES(`esn`) uses Hurlbert's
#' formula through `lgamma()`, which is defined for the real-valued counts; it
#' is NA where the weighted `n` is below `esn`. Places with no records in a
#' layer have no row for it.
#'
#' @param con connection to an obis_h3 store with `occ_h3` (read-only is
#'   fine), with the duckdb `h3` extension loaded (see [obis_store_connect()]).
#' @param membership the place-cell membership, columns `place_id`, `h3` (hex
#'   string) and `share`: a data frame, the name of a table or view in `con`,
#'   a character vector of parquet paths or URLs, a gazetteer collection
#'   (directory, URL, `membership.json` or slug, see
#'   [obis_place_membership()]), or the list that function returns. Its cells
#'   must be at resolution `res`.
#' @param esn expected sample size for ES(n); default 50.
#' @param res H3 resolution of the membership cells (default 7). The store's
#'   `occ_h3` tier for `res` is used; finer tiers are rolled up to `res`.
#' @param decades decades (first year) to compute besides all years: `TRUE`
#'   (default) for 1960-2020 as in the export, `FALSE` or `NULL` for none, or
#'   an integer vector.
#' @param eov EOV layers: `TRUE` (default) every EOV in the store's `eov` table
#'   (skipped when the store has none), `FALSE` none, or EOV names.
#' @param verbose message progress.
#'
#' @return a data frame, one row per (place, layer, key, decade) with records:
#'   `place_id`, `layer` (`"all"` or `"eov"`), `key` (`""` or the EOV name),
#'   `decade` (NA = all years), `n` (sum of records x share, double), `sp`
#'   (species with a weighted count > 0), `shannon`, `simpson` (sum of p^2),
#'   `es` (ES(`esn`) on the weighted counts, NA where `n < esn`), `cells`
#'   (member cells with records in that layer and decade) and `area` (sum of
#'   `share` over those cells, in cells).
#' @concept analyze
#' @export
#' @examples
#' \dontrun{
#' con <- obis_store_connect("~/data/obis/obis_h3.duckdb")
#' obis_place_indicators(con, "noaa_aoa_socal")
#' }
obis_place_indicators <- function(
  con, membership, esn = 50L, res = 7L, decades = TRUE, eov = TRUE, verbose = FALSE) {

  stopifnot(requireNamespace("DBI", quietly = TRUE),
            requireNamespace("duckdb", quietly = TRUE),
            is.numeric(esn), length(esn) == 1L,
            is.numeric(res), length(res) == 1L, res %in% 1:7)
  esn  <- as.integer(esn)
  res  <- as.integer(res)
  tier <- .obis_tier(res)
  say  <- function(...) if (verbose) message(...)

  if (isTRUE(decades)) decades <- seq(1960L, 2020L, by = 10L)
  if (isFALSE(decades)) decades <- NULL
  if (length(decades)) {
    stopifnot(is.numeric(decades), all(decades %% 10 == 0))
    decades <- sort(unique(as.integer(decades)))
  }

  has_eov_tbl <- .obis_has_table(con, "eov")
  eovs <- if (isFALSE(eov) || is.null(eov)) character(0) else if (isTRUE(eov)) {
    if (has_eov_tbl) DBI::dbGetQuery(con, "SELECT DISTINCT eov FROM eov ORDER BY 1")$eov else {
      say("skipping eov: no eov table"); character(0) }
  } else {
    if (!has_eov_tbl) stop("store has no eov table (see obis_eov_bake())")
    .obis_eov_names(eov)
  }

  # the membership as a temp table: (place_id, cell_id BIGINT, share DOUBLE) ----
  src <- .place_membership_src(con, membership, res)
  on.exit(src$cleanup(), add = TRUE)
  mt  <- paste0("_place_m_", as.integer(stats::runif(1, 1e6, 1e7)))
  DBI::dbExecute(con, glue::glue("
    CREATE TEMP TABLE {mt} AS
    SELECT place_id::VARCHAR AS place_id,
           CAST(h3_string_to_h3(lower(h3::VARCHAR)) AS BIGINT) AS cell_id,
           MAX(share::DOUBLE) AS share
    FROM {src$from}
    WHERE share > 0
    GROUP BY 1, 2"))
  on.exit(DBI::dbExecute(con, glue::glue("DROP TABLE IF EXISTS {mt}")), add = TRUE)
  m_res <- DBI::dbGetQuery(con, glue::glue(
    "SELECT DISTINCT h3_get_resolution(cell_id)::INTEGER AS r FROM {mt}"))$r
  if (length(m_res) && !all(m_res == res))
    stop("membership cells are at res ", paste(sort(m_res), collapse = ", "),
         ", not res ", res)

  cell_expr <- if (tier == res) "o.cell_id" else
    glue::glue("CAST(h3_cell_to_parent(o.cell_id, {res}) AS BIGINT)")
  dec_expr  <- "CAST(floor(o.date_year / 10) * 10 AS INTEGER)"

  # one query per (layer, all years | by decade) ----
  part <- function(layer, by_decade) {
    key_expr <- if (layer == "eov") "e.eov" else "''"
    join_eov <- if (layer == "eov") glue::glue(
      "JOIN eov e ON o.aphiaid = e.taxonID AND e.eov IN ({paste(.h3t_sql_quote(eovs), collapse = ', ')})") else ""
    where <- glue::glue("o.res = {tier}")
    if (by_decade) where <- glue::glue(
      "{where} AND o.date_year IS NOT NULL AND {dec_expr} IN ({paste(decades, collapse = ', ')})")
    keys   <- if (by_decade) c("key", "decade") else "key"
    dec_in <- if (by_decade) glue::glue("{dec_expr} AS decade, ") else ""
    dec_out <- if (by_decade) "i.decade" else "NULL::INTEGER"
    # place_id stands in for cell_id: .h3t_indicators_sql() always groups by cell_id
    ind <- .h3t_indicators_sql(glue::glue("
        SELECT place_id AS cell_id, {paste(keys, collapse = ', ')}, species,
               SUM(records * share) AS ni
        FROM lay GROUP BY ALL"),
      keys = keys, select = paste(c("cell_id AS place_id", keys), collapse = ", "), esn = esn)
    glue::glue("
      WITH lay AS (
        SELECT m.place_id, m.cell_id AS mcell, m.share, {key_expr} AS key, {dec_in}
               o.species, o.records
        FROM occ_h3 o
        JOIN {mt} m ON {cell_expr} = m.cell_id
        {join_eov}
        WHERE {where}),
      ind AS ({ind}),
      cov AS (
        SELECT place_id, {paste(keys, collapse = ', ')},
               COUNT(*)::INTEGER AS cells, SUM(share) AS area
        FROM (SELECT DISTINCT place_id, {paste(keys, collapse = ', ')}, mcell, share FROM lay)
        GROUP BY ALL)
      SELECT i.place_id, '{layer}' AS layer, i.key, {dec_out} AS decade,
             i.n::DOUBLE AS n, i.sp::INTEGER AS sp, i.shannon::DOUBLE AS shannon,
             i.simpson::DOUBLE AS simpson, i.es::DOUBLE AS es, c.cells, c.area::DOUBLE AS area
      FROM ind i JOIN cov c USING (place_id, {paste(keys, collapse = ', ')})")
  }
  sqls <- list(part("all", FALSE))
  if (length(decades)) sqls <- c(sqls, list(part("all", TRUE)))
  if (length(eovs)) {
    sqls <- c(sqls, list(part("eov", FALSE)))
    if (length(decades)) sqls <- c(sqls, list(part("eov", TRUE)))
  }
  say("place indicators: ", length(sqls), " queries over occ_h3 tier ", tier, " ...")
  sql <- paste0(
    "SELECT * FROM (\n", paste0("SELECT * FROM (", sqls, ")", collapse = "\nUNION ALL BY NAME\n"), "\n) ",
    "ORDER BY place_id, layer, key, decade NULLS FIRST")
  out <- DBI::dbGetQuery(con, sql)
  rownames(out) <- NULL
  out
}

# a membership argument as a FROM clause (and how to clean up after it) ----
.place_membership_src <- function(con, membership, res) {
  nothing <- function() invisible(NULL)
  if (is.data.frame(membership)) {
    stopifnot(all(c("place_id", "h3", "share") %in% names(membership)))
    vw <- paste0("_place_df_", as.integer(stats::runif(1, 1e6, 1e7)))
    duckdb::duckdb_register(con, vw, membership[, c("place_id", "h3", "share")])
    return(list(from = vw, cleanup = function() duckdb::duckdb_unregister(con, vw)))
  }
  if (is.list(membership) && !is.null(membership$files)) {
    if (!is.null(membership$res) && !identical(as.integer(membership$res), res))
      stop("membership is at res ", membership$res, ", not res ", res)
    membership <- membership$files
  }
  stopifnot(is.character(membership), length(membership) >= 1L)
  if (length(membership) == 1L && membership %in% DBI::dbListTables(con))
    return(list(from = as.character(DBI::dbQuoteIdentifier(con, membership)), cleanup = nothing))
  # a collection (dir, URL, membership.json or slug) rather than parquet files
  if (length(membership) == 1L && !grepl("\\.parquet$", membership))
    membership <- obis_place_membership(membership, res)$files
  files <- paste(.h3t_sql_quote(path.expand(membership)), collapse = ", ")
  list(from = glue::glue("read_parquet([{files}], hive_partitioning = false)"),
       cleanup = nothing)
}
