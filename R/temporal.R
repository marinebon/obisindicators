# decadal (or any period) subsets of the indicators, computed live from the
# species-level occ_h3 store via the year-filtered tile SQL, so the math stays
# the one pinned to calc_indicators(). paper Fig. 5.

#' Indicators per period (e.g. decade) and cell
#'
#' Runs the year-filtered live tile SQL once per period and returns `n`, `sp`
#' and `es` per cell and period. Periods are `[start, start + width - 1]`.
#'
#' @inheritParams obis_cell_indicators
#' @param res H3 resolution (coarse, e.g. 2-3, is sensible: the denominator
#'   thins quickly when records are split by decade).
#' @param starts period start years (default decades 1960-2020).
#' @param width period width in years (default 10).
#'
#' @return data frame with `period`, `cell`, `n`, `sp`, `es`.
#' @concept analyze
#' @export
calc_period_indicators <- function(
  con, res = 2L, eov = NULL, aphiaid = NULL, taxon = NULL,
  starts = seq(1960L, 2020L, by = 10L), width = 10L, esn = 50L) {

  rows <- lapply(as.integer(starts), function(s) {
    d <- obis_cell_indicators(
      con, res, eov = eov, aphiaid = aphiaid, taxon = taxon,
      years = c(s, s + as.integer(width) - 1L), esn = esn, live = TRUE)
    if (!nrow(d)) return(NULL)
    cbind(period = s, d[, c("cell", "n", "sp", "es")], stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, rows)
  if (is.null(out))
    out <- data.frame(period = integer(0), cell = character(0), n = numeric(0),
                      sp = numeric(0), es = numeric(0))
  rownames(out) <- NULL
  out
}

#' Change in an indicator between two periods, where both are reliable
#'
#' Joins the cells of two periods from [calc_period_indicators()] and keeps
#' those with `n >= esn` in both, so ES(n) is defined on each side. Also
#' reports how coverage changed (cells reliable only in one period).
#'
#' @param df output of [calc_period_indicators()].
#' @param from,to the two `period` values to compare.
#' @param esn reliability floor on `n` (default 50, the ES(50) floor).
#' @param indicator which indicator to difference (`"es"` or `"sp"`).
#'
#' @return list with `cells` (cell, value_from, value_to, delta, pct, n_from,
#'   n_to) and `coverage` (counts of cells reliable in both / only from / only
#'   to).
#' @concept analyze
#' @export
calc_period_change <- function(df, from, to, esn = 50L, indicator = c("es", "sp")) {
  indicator <- match.arg(indicator)
  a <- df[df$period == from & df$n >= esn, c("cell", "n", indicator)]
  b <- df[df$period == to   & df$n >= esn, c("cell", "n", indicator)]
  names(a) <- c("cell", "n_from", "value_from")
  names(b) <- c("cell", "n_to",   "value_to")
  m <- merge(a, b, by = "cell")
  m$delta <- m$value_to - m$value_from
  m$pct   <- 100 * m$delta / m$value_from
  m <- m[, c("cell", "value_from", "value_to", "delta", "pct", "n_from", "n_to")]
  coverage <- data.frame(
    both      = nrow(m),
    only_from = sum(!a$cell %in% b$cell),
    only_to   = sum(!b$cell %in% a$cell))
  list(cells = m, coverage = coverage)
}
