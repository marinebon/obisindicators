# how indicators and their reliability change across H3 resolutions (the
# "scale curves" of the paper, Fig. 3). built on obis_cell_indicators() and
# obis_spue_sql(), so no indicator math is duplicated here.

#' Scale curves: indicator summaries across H3 resolutions
#'
#' For one filter (all taxa, an EOV, an AphiaID subtree or DwC rank values),
#' summarizes the per-cell indicators at each resolution: occupied cells,
#' records, the distribution of records per cell, the fraction of cells where
#' ES(n) is defined (`n >= esn`), and medians of ES(n) and richness among
#' those. `n_cells_all` is the number of cells occupied by *any* taxon at that
#' resolution (from `idx_h3`), so `frac_cells_all` reads as the filter's
#' footprint relative to all sampling.
#'
#' @inheritParams obis_cell_indicators
#' @param res resolutions to evaluate (default 1:7).
#' @param floors record-count floors for the reliability columns
#'   `frac_n_ge_<floor>` (default 10, 30, 100).
#' @param group optional label carried in a `group` column (handy when
#'   binding curves for several EOVs).
#'
#' @return data frame, one row per resolution.
#' @concept analyze
#' @export
calc_scale_curves <- function(
  con, res = 1:7, eov = NULL, aphiaid = NULL, taxon = NULL, years = NULL,
  esn = 50L, floors = c(10L, 30L, 100L), group = NULL) {

  stopifnot(requireNamespace("DBI", quietly = TRUE))
  has_idx <- .obis_has_table(con, "idx_h3")

  rows <- lapply(as.integer(res), function(r) {
    d <- obis_cell_indicators(
      con, r, eov = eov, aphiaid = aphiaid, taxon = taxon, years = years,
      esn = esn)
    n_all <- if (has_idx) as.numeric(DBI::dbGetQuery(con, glue::glue(
      "SELECT COUNT(*) AS n FROM idx_h3 WHERE res = {r}"))$n) else NA_real_
    elig <- d$n >= esn
    out <- data.frame(
      res            = r,
      area_km2       = H3_RES_TABLE$area_km2[H3_RES_TABLE$res == r],
      n_cells        = nrow(d),
      n_cells_all    = n_all,
      frac_cells_all = nrow(d) / n_all,
      records        = sum(as.numeric(d$n)),
      median_n       = stats::median(as.numeric(d$n)),
      q25_n          = unname(stats::quantile(as.numeric(d$n), 0.25)),
      q75_n          = unname(stats::quantile(as.numeric(d$n), 0.75)),
      frac_eligible  = mean(elig),
      median_es      = if (any(elig)) stats::median(d$es[elig], na.rm = TRUE) else NA_real_,
      median_sp      = stats::median(as.numeric(d$sp)),
      median_sp_elig = if (any(elig)) stats::median(as.numeric(d$sp[elig])) else NA_real_,
      stringsAsFactors = FALSE)
    for (f in floors)
      out[[paste0("frac_n_ge_", f)]] <- mean(as.numeric(d$n) >= f)
    out
  })
  out <- do.call(rbind, rows)
  if (!is.null(group)) out <- cbind(group = group, out, stringsAsFactors = FALSE)
  out
}

#' Scale curves for the SPUE effort proxy
#'
#' How the effort denominator thins with resolution: per resolution, the number
#' of effort cells, the median effort count, the fraction of effort cells below
#' each reliability floor, and the fraction of effort cells where the target
#' was seen at all.
#'
#' @param con connection from [obis_store_connect()].
#' @param num_aphiaid,den_aphiaid target / effort AphiaID(s); see [obis_spue_sql()].
#' @param res resolutions (default 1:7).
#' @param floors effort-count floors (default 10, 30, 100).
#' @param group optional label carried in a `group` column.
#'
#' @return data frame, one row per resolution.
#' @concept analyze
#' @export
calc_spue_scale <- function(
  con, num_aphiaid, den_aphiaid, res = 1:7, floors = c(10L, 30L, 100L),
  group = NULL) {

  rows <- lapply(as.integer(res), function(r) {
    d <- obis_h3t_query(
      con, obis_spue_sql(num_aphiaid, den_aphiaid, res_placeholder = as.character(r)), r)
    eff <- as.numeric(d$n)
    out <- data.frame(
      res            = r,
      area_km2       = H3_RES_TABLE$area_km2[H3_RES_TABLE$res == r],
      n_cells_effort = nrow(d),
      effort_records = sum(eff),
      median_effort  = stats::median(eff),
      frac_present   = mean(d$value > 0, na.rm = TRUE),
      median_spue    = stats::median(d$value, na.rm = TRUE),
      stringsAsFactors = FALSE)
    for (f in floors)
      out[[paste0("frac_effort_lt_", f)]] <- mean(eff < f)
    out
  })
  out <- do.call(rbind, rows)
  if (!is.null(group)) out <- cbind(group = group, out, stringsAsFactors = FALSE)
  out
}
