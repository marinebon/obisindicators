#' Statically map indicators using ggplot
#'
#' @param grid spatial features, e.g. hexagons, to plot; requires a geometry
#'   spatial column
#' @param column column name with indicator; default="shannon"
#' @param label label to show on legend
#' @param crs coordinate reference system; see `sf::st_crs()`
#' @param trans For continuous scales, the name of a transformation object or
#'   the object itself. Built-in transformations include "asn", "atanh",
#'   "boxcox", "date", "exp", "hms", "identity" (default), "log", "log10", "log1p",
#'   "log2", "logit", "modulus", "probability", "probit", "pseudo_log",
#'   "reciprocal", "reverse", "sqrt" and "time". See `ggplot2::continuous_scale`
#' @param bbox optional `sf::st_bbox()` (in lon/lat) to frame the map; default
#'   the extent of `grid`.
#'
#' @return ggplot2 plot
#' @concept visualize
#' @export
#' @import rnaturalearth viridis ggplot2
#'
#' @examples
gmap_indicator <- function(
    grid, column = "shannon", label = "Shannon index", trans = "identity",
    crs="+proj=robin +lon_0=0 +x_0=0 +y_0=0 +ellps=WGS84 +datum=WGS84 +units=m +no_defs",
    bbox = NULL){

  world <- rnaturalearth::ne_countries(scale = "medium", returnclass = "sf")
  frame <- if (is.null(bbox)) grid else
    sf::st_as_sfc(sf::st_bbox(bbox, crs = sf::st_crs(4326)))
  bb <- sf::st_bbox(sf::st_transform(frame, crs))

  p <- ggplot() +
    geom_sf(
      data = grid, aes(fill = .data[[column]]), lwd = 0, color = NA) +
    viridis::scale_fill_viridis(
      option = "inferno", na.value = "white",
      name = label, trans = trans) +
    geom_sf(
      data = world, fill = "#dddddd", color = NA) +
    theme(
      panel.grid.major.x = element_blank(),
      panel.grid.major.y = element_blank(),
      panel.grid.minor.x = element_blank(),
      panel.grid.minor.y = element_blank(),
      panel.background = element_blank(),
      axis.text.x = element_blank(),
      axis.text.y = element_blank(),
      axis.ticks = element_blank(),
      axis.title.x = element_blank(),
      axis.title.y = element_blank()) +
    xlab("") + ylab("") +
    coord_sf(
      crs  = crs,
      xlim = bb[c("xmin","xmax")],
      ylim = bb[c("ymin","ymax")])
  return(p)
}

#' H3 cells (hex strings) to `sf` polygons
#'
#' Vectorized boundary lookup with dateline wrapping, the same treatment as
#' [make_hex_res()] but for an arbitrary set of cells (e.g. the `cell` column
#' returned by [obis_cell_indicators()]).
#'
#' @param cells character vector of H3 indexes.
#' @param dl_offset `DATELINEOFFSET` passed to `sf::st_wrap_dateline()`;
#'   default 60 (enough for res >= 1).
#'
#' @return `sf` with columns `cell` and `geometry`, one row per input cell.
#' @concept visualize
#' @export
hex_sf <- function(cells, dl_offset = 60) {
  cells <- as.character(cells)
  s <- h3::h3_to_geo_boundary_sf(cells)
  s <- sf::st_wrap_dateline(s, c("WRAPDATELINE=YES", glue::glue("DATELINEOFFSET={dl_offset}")))
  s$cell <- cells
  s[, c("cell", attr(s, "sf_column"))]
}

#' Map a per-cell table of indicators
#'
#' Joins a data frame keyed on `cell` (hex string) to hexagon polygons and
#' draws it with [gmap_indicator()].
#'
#' @param df data frame with a `cell` column (e.g. from
#'   [obis_cell_indicators()], [calc_spue_cells()]).
#' @param column column to fill by (default `"es"`).
#' @param label legend label (default `column`).
#' @param trans scale transformation (see [gmap_indicator()]).
#' @param mask optional logical vector (same length as `df`) — cells where
#'   `FALSE` are drawn with `NA` fill (e.g. `df$n >= 50` to mask unreliable
#'   ES(50)).
#' @param ... passed to [gmap_indicator()] (`crs`, `bbox`).
#'
#' @return ggplot2 plot
#' @concept visualize
#' @export
gmap_cells <- function(df, column = "es", label = column, trans = "identity",
                       mask = NULL, ...) {
  stopifnot("cell" %in% names(df), column %in% names(df))
  grid <- hex_sf(df$cell)
  grid[[column]] <- df[[column]]
  if (!is.null(mask)) grid[[column]][!mask] <- NA
  gmap_indicator(grid, column = column, label = label, trans = trans, ...)
}

#' Plot scale curves
#'
#' Small multiples of the summaries from [calc_scale_curves()] (or
#' [calc_spue_scale()]) against H3 resolution, one line per `group` when
#' present. Metrics named in `log_y` are drawn as `log10(metric)`.
#'
#' @param df output of [calc_scale_curves()] / [calc_spue_scale()], possibly
#'   several bound together with a `group` column.
#' @param metrics columns to plot (default the four headline curves).
#' @param log_y metrics to draw on a log10 scale.
#'
#' @return ggplot2 plot
#' @concept visualize
#' @export
plot_scale_curves <- function(
  df,
  metrics = c("n_cells", "median_n", "frac_eligible", "median_es"),
  log_y   = c("n_cells", "median_n")) {

  metrics <- intersect(metrics, names(df))
  stopifnot(length(metrics) > 0)
  if (!"group" %in% names(df)) df$group <- "all"
  long <- dplyr::bind_rows(lapply(metrics, function(m) {
    v   <- as.numeric(df[[m]])
    lbl <- m
    if (m %in% log_y) { v <- log10(v); lbl <- paste0("log10(", m, ")") }
    data.frame(group = df$group, res = df$res, metric = lbl, value = v,
               stringsAsFactors = FALSE)
  }))
  lvls <- ifelse(metrics %in% log_y, paste0("log10(", metrics, ")"), metrics)
  long$metric <- factor(long$metric, levels = lvls)

  ggplot(long, aes(x = res, y = value, color = group, group = group)) +
    geom_line() + geom_point(size = 1.6) +
    facet_wrap(~ metric, scales = "free_y") +
    scale_x_continuous(breaks = sort(unique(long$res))) +
    labs(x = "H3 resolution", y = NULL, color = NULL) +
    theme_minimal(base_size = 11) +
    theme(legend.position = "bottom", panel.grid.minor = element_blank())
}

#' Plot SPUE-vs-model calibration
#'
#' Mean modeled value (with ±1 SD) per SPUE bin from [compare_spue_sdm()].
#'
#' @param cmp output of [compare_spue_sdm()].
#' @param ylab y-axis label (default "modeled suitability").
#'
#' @return ggplot2 plot
#' @concept visualize
#' @export
plot_spue_sdm <- function(cmp, ylab = "modeled suitability") {
  calib <- cmp$calib
  stopifnot(nrow(calib) > 0)
  calib$bin_lbl <- ifelse(calib$bin == 0, "0 (absent)", as.character(calib$bin))
  calib$bin_lbl <- factor(calib$bin_lbl, levels = unique(calib$bin_lbl[order(calib$bin)]))
  sub <- sprintf("Spearman rho = %.2f (n = %d cells, effort-gated)",
                 cmp$stats$rho, as.integer(cmp$stats$n_cells))
  ggplot(calib, aes(x = bin_lbl, y = sdm_mean)) +
    geom_col(fill = "#4c78a8", width = .7) +
    geom_errorbar(aes(ymin = sdm_mean - sdm_sd, ymax = sdm_mean + sdm_sd), width = .2) +
    geom_text(aes(label = n_cells, y = 0), vjust = 1.4, size = 3, color = "grey30") +
    labs(x = "SPUE bin (0 = effort, no target; 1.. = quantiles of positive SPUE)",
         y = ylab, subtitle = sub) +
    theme_minimal(base_size = 11)
}
