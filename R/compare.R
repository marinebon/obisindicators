# comparisons that carry the paper's arguments: rank-column filters vs
# AphiaID subtrees (Table 3), EOV totals before/after a taxonomy change
# (Table 4), and the SPUE effort proxy against modeled habitat suitability
# aggregated to the same H3 cells (Fig. 4).

#' Default taxon-group presets for the rank-vs-subtree comparison
#'
#' The h3-db app's taxon groups, each as the DwC rank column a user would
#' naively filter on and the WoRMS AphiaID that seeds the subtree. Two of them
#' (Actinopterygii, Anthozoa) are filed at a different rank by WoRMS/OBIS and
#' match nothing by rank column — the point of [calc_rank_vs_subtree()].
#'
#' @return data frame with `label`, `rank`, `name`, `aphiaid`.
#' @concept analyze
#' @export
obis_rank_presets <- function() {
  data.frame(
    label   = c("Seabirds", "Bony fishes", "Sharks & rays", "Marine mammals",
                "Sea turtles", "Corals & anemones", "Mollusks", "Crustaceans"),
    rank    = c("class", "class", "class", "class", "order", "class", "phylum", "class"),
    name    = c("Aves", "Actinopterygii", "Elasmobranchii", "Mammalia",
                "Testudines", "Anthozoa", "Mollusca", "Malacostraca"),
    aphiaid = c(1836L, 10194L, 10193L, 1837L, 2689L, 1292L, 51L, 1071L),
    stringsAsFactors = FALSE)
}

#' Records and species by DwC rank column vs by AphiaID subtree
#'
#' For each preset, counts records and species at the base resolution two
#' ways: filtering the Darwin Core rank column (`"<rank>" = '<name>'`) and
#' filtering `aphiaid` by the recursive WoRMS subtree of the seed id. Where
#' WoRMS files the name at a rank other than the column (e.g. Actinopterygii is
#' a gigaclass; OBIS's `class` carries Teleostei), the rank column silently
#' returns zero while the subtree finds the records.
#'
#' @param con connection from [obis_store_connect()].
#' @param presets data frame with `label`, `rank`, `name`, `aphiaid`; default
#'   [obis_rank_presets()].
#' @param res resolution tier of `occ_h3` to count on (default the base, 7).
#'
#' @return data frame with `label`, `rank`, `name`, `aphiaid`, `records_rank`,
#'   `species_rank`, `records_tree`, `species_tree`, `ratio`
#'   (`records_rank / records_tree`).
#' @concept analyze
#' @export
calc_rank_vs_subtree <- function(con, presets = obis_rank_presets(), res = H3T_RES_BASE) {
  stopifnot(requireNamespace("DBI", quietly = TRUE),
            all(c("label", "rank", "name", "aphiaid") %in% names(presets)))
  res <- as.integer(res)
  rows <- lapply(seq_len(nrow(presets)), function(i) {
    p  <- presets[i, ]
    wc <- .h3t_where_clause(taxon = stats::setNames(list(p$name), p$rank))
    by_rank <- DBI::dbGetQuery(con, glue::glue("
      SELECT COALESCE(SUM(records), 0) AS records, COUNT(DISTINCT species) AS species
      FROM occ_h3 WHERE res = {res} {wc}"))
    cte <- .h3t_taxon_tree_cte(p$aphiaid)
    by_tree <- DBI::dbGetQuery(con, glue::glue("
      WITH RECURSIVE {cte}
      SELECT COALESCE(SUM(records), 0) AS records, COUNT(DISTINCT species) AS species
      FROM occ_h3 WHERE res = {res}
        AND aphiaid IN (SELECT taxonID FROM taxon_tree)"))
    data.frame(
      label = p$label, rank = p$rank, name = p$name, aphiaid = p$aphiaid,
      records_rank = as.numeric(by_rank$records),
      species_rank = as.numeric(by_rank$species),
      records_tree = as.numeric(by_tree$records),
      species_tree = as.numeric(by_tree$species),
      stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, rows)
  out$ratio <- ifelse(out$records_tree > 0, out$records_rank / out$records_tree, NA_real_)
  out
}

#' Records, species and cells per Essential Ocean Variable
#'
#' Totals at the base resolution for each EOV, via the baked `eov` membership
#' table when present, else by resolving each EOV's seed subtree live.
#'
#' @param con connection from [obis_store_connect()].
#' @param eov EOV name(s); default all.
#' @param res resolution tier of `occ_h3` to count on (default 7).
#'
#' @return data frame with `eov`, `label`, `records`, `species`, `cells`,
#'   `pct_records` (share of all records at that tier).
#' @concept analyze
#' @export
calc_eov_totals <- function(con, eov = NULL, res = H3T_RES_BASE) {
  stopifnot(requireNamespace("DBI", quietly = TRUE))
  nms <- if (is.null(eov)) names(OBIS_EOV) else .obis_eov_names(eov)
  res <- as.integer(res)
  tot <- as.numeric(DBI::dbGetQuery(con, glue::glue(
    "SELECT SUM(records) AS n FROM occ_h3 WHERE res = {res}"))$n)

  rows <- lapply(nms, function(k) {
    d <- if (.obis_has_table(con, "eov")) {
      DBI::dbGetQuery(con, glue::glue("
        SELECT COALESCE(SUM(o.records), 0) AS records,
               COUNT(DISTINCT o.aphiaid) AS species,
               COUNT(DISTINCT o.cell_id) AS cells
        FROM occ_h3 o JOIN eov e ON o.aphiaid = e.taxonID
        WHERE o.res = {res} AND e.eov = '{k}'"))
    } else {
      cte <- .h3t_taxon_tree_cte(OBIS_EOV[[k]]$aphiaid)
      DBI::dbGetQuery(con, glue::glue("
        WITH RECURSIVE {cte}
        SELECT COALESCE(SUM(records), 0) AS records,
               COUNT(DISTINCT aphiaid) AS species,
               COUNT(DISTINCT cell_id) AS cells
        FROM occ_h3 WHERE res = {res}
          AND aphiaid IN (SELECT taxonID FROM taxon_tree)"))
    }
    data.frame(eov = k, label = OBIS_EOV[[k]]$label,
               records = as.numeric(d$records), species = as.numeric(d$species),
               cells = as.numeric(d$cells), stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, rows)
  out$pct_records <- 100 * out$records / tot
  out
}

#' Compare EOV totals between two stores (e.g. before/after taxonomy gap-fill)
#'
#' @param before,after outputs of [calc_eov_totals()] from the two stores.
#' @return data frame with `eov`, `label`, `records_before`, `records_after`,
#'   `records_delta`, `records_pct`, `species_before`, `species_after`,
#'   `cells_before`, `cells_after`.
#' @concept analyze
#' @export
compare_eov_totals <- function(before, after) {
  m <- merge(before, after, by = c("eov", "label"), suffixes = c("_before", "_after"))
  m$records_delta <- m$records_after - m$records_before
  m$records_pct   <- ifelse(m$records_before > 0,
                            100 * m$records_delta / m$records_before, NA_real_)
  m[, c("eov", "label", "records_before", "records_after", "records_delta",
        "records_pct", "species_before", "species_after",
        "cells_before", "cells_after")]
}

#' SPUE effort proxy per cell at one resolution
#'
#' Runs [obis_spue_sql()] at a fixed resolution and returns, per effort cell,
#' the target and effort record counts and their ratio.
#'
#' @inheritParams obis_spue_sql
#' @param con connection from [obis_store_connect()].
#' @param res H3 resolution (1-7).
#'
#' @return data frame with `cell`, `spue`, `effort` (denominator records),
#'   `target` (numerator records).
#' @concept analyze
#' @export
calc_spue_cells <- function(con, num_aphiaid, den_aphiaid, res) {
  d <- obis_h3t_query(
    con, obis_spue_sql(num_aphiaid, den_aphiaid, res_placeholder = as.character(res)),
    res)
  data.frame(
    cell   = d$cell,
    spue   = d$value,
    effort = as.numeric(d$n),
    target = round(d$value * as.numeric(d$n)),
    stringsAsFactors = FALSE)
}

#' Aggregate a raster (e.g. an SDM) to H3 cells
#'
#' Two strategies: `"centers"` assigns every non-NA raster cell centre to an
#' H3 cell at `res` and averages (right when hexagons are larger than raster
#' cells); `"centroids"` samples the raster at each requested hexagon's
#' centroid (right when hexagons are smaller). `"auto"` picks centres when the
#' mean hexagon area is at least `ratio` times the raster cell area.
#'
#' @param r a `terra::SpatRaster` (single layer, lon/lat).
#' @param res H3 resolution.
#' @param cells optional hex strings to restrict/sample to (required for
#'   `"centroids"`).
#' @param method `"auto"`, `"centers"` or `"centroids"`.
#' @param ratio hexagon-to-raster-cell area ratio above which `"auto"` uses
#'   centres (default 3).
#'
#' @return data frame with `cell`, `value` (mean), `n_px` (raster cells
#'   averaged; 1 for centroid sampling).
#' @concept analyze
#' @export
h3_raster_to_cells <- function(
  r, res, cells = NULL, method = c("auto", "centers", "centroids"), ratio = 3) {

  stopifnot(requireNamespace("terra", quietly = TRUE), inherits(r, "SpatRaster"))
  method <- match.arg(method)
  res    <- as.integer(res)
  if (terra::nlyr(r) > 1) r <- r[[1]]

  if (method == "auto") {
    px_km2  <- prod(terra::res(r)) * 111^2      # degrees -> km at the equator
    hex_km2 <- H3_RES_TABLE$area_km2[H3_RES_TABLE$res == res]
    method  <- if (hex_km2 >= ratio * px_km2 || is.null(cells)) "centers" else "centroids"
  }

  if (method == "centers") {
    v   <- terra::values(r, mat = FALSE)
    ok  <- which(!is.na(v))
    xy  <- terra::xyFromCell(r, ok)
    d   <- data.frame(
      cell  = h3::geo_to_h3(data.frame(lat = xy[, 2], lng = xy[, 1]), res = res),
      value = v[ok], stringsAsFactors = FALSE)
    out <- d |>
      dplyr::group_by(cell) |>
      dplyr::summarize(value = mean(value), n_px = dplyr::n(), .groups = "drop")
    if (!is.null(cells)) out <- out[out$cell %in% cells, ]
    return(as.data.frame(out))
  }

  if (is.null(cells)) stop("`cells` is required for method = 'centroids'")
  ll <- h3::h3_to_geo(cells)                       # lat, lng
  v  <- terra::extract(r, cbind(ll[, "lng"], ll[, "lat"]))[, 1]
  data.frame(cell = cells, value = v, n_px = 1L, stringsAsFactors = FALSE)
}

#' Compare the SPUE effort proxy with modeled suitability
#'
#' Joins per-cell SPUE ([calc_spue_cells()]) with a model surface aggregated
#' to the same cells ([h3_raster_to_cells()]), keeps cells with at least
#' `min_effort` effort records, and reports Spearman's rank correlation plus a
#' calibration table: mean model value by SPUE bin (bin 0 = target never
#' recorded despite effort; bins 1..`n_bins` = quantile bins of positive SPUE).
#'
#' @param spue output of [calc_spue_cells()].
#' @param sdm output of [h3_raster_to_cells()] (`cell`, `value`).
#' @param min_effort effort floor (default 30 records).
#' @param n_bins number of positive-SPUE quantile bins (default 5).
#'
#' @return list with `stats` (n_cells, rho, p_value, frac_present),
#'   `calib` (bin, n_cells, spue_mean, sdm_mean, sdm_sd) and `data` (the
#'   joined cells).
#' @concept analyze
#' @export
compare_spue_sdm <- function(spue, sdm, min_effort = 30L, n_bins = 5L) {
  stopifnot(all(c("cell", "spue", "effort") %in% names(spue)),
            all(c("cell", "value") %in% names(sdm)))
  d <- spue |>
    dplyr::inner_join(dplyr::select(sdm, cell, sdm = value), by = "cell") |>
    dplyr::filter(effort >= min_effort, !is.na(sdm), !is.na(spue))

  if (nrow(d) < 3)
    return(list(
      stats = data.frame(n_cells = nrow(d), rho = NA_real_, p_value = NA_real_,
                         frac_present = NA_real_),
      calib = data.frame(), data = d))

  ct <- suppressWarnings(stats::cor.test(d$spue, d$sdm, method = "spearman", exact = FALSE))
  stats <- data.frame(
    n_cells      = nrow(d),
    rho          = unname(ct$estimate),
    p_value      = ct$p.value,
    frac_present = mean(d$spue > 0))

  pos <- d$spue > 0
  d$bin <- 0L
  if (any(pos))
    d$bin[pos] <- dplyr::ntile(d$spue[pos], min(as.integer(n_bins), sum(pos)))
  calib <- d |>
    dplyr::group_by(bin) |>
    dplyr::summarize(
      n_cells   = dplyr::n(),
      spue_mean = mean(spue),
      sdm_mean  = mean(sdm),
      sdm_sd    = stats::sd(sdm),
      .groups   = "drop")

  list(stats = stats, calib = as.data.frame(calib), data = d)
}
