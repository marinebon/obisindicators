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
