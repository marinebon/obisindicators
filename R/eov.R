# Essential Ocean Variables (EOVs) as WoRMS AphiaID subtrees.
#
# GOOS/IOOS define the biology & ecosystems EOVs by taxonomy, and the IOOS
# Marine Life Data Network publishes that definition as a short list of root
# AphiaIDs per EOV:
#   https://github.com/ioos/marine_life_data_network/tree/main/eov_taxonomy
# (`IdentifierList.csv`; the per-EOV CSVs there carry the same seeds plus WoRMS
# classification strings). The whole definition is 38 AphiaIDs across 7 EOVs.
#
# Mapping that onto this package is just a multi-seed version of what
# R/taxon.R already does: expand each EOV's seeds to their full descendant set
# over the baked WoRMS `taxon` table, then filter `occ_h3.aphiaid` by it.
#
# Why seeds-and-subtree rather than the DwC rank columns (`class = 'Aves'`):
# the rank a name occupies is not stable across the hierarchy, so a rank-column
# match silently returns NOTHING whenever OBIS's interpreted classification puts
# the name at a different rank. Observed on the 2026-07 global store:
#   class = 'Actinopterygii' -> 0 records   (WoRMS ranks it a Gigaclass; OBIS's
#                                            class for bony fish is 'Teleostei')
#   class = 'Anthozoa'       -> 0 records   (a Subphylum; OBIS uses
#                                            'Hexacorallia' / 'Octocorallia')
# Subtree walking is rank-agnostic and therefore immune to that failure mode.

#' The IOOS Marine Life Data Network EOV definitions
#'
#' Root WoRMS AphiaIDs per Essential Ocean Variable, transcribed from
#' [ioos/marine_life_data_network](https://github.com/ioos/marine_life_data_network/tree/main/eov_taxonomy)
#' `eov_taxonomy/IdentifierList.csv`. Each EOV is the union of the descendant
#' subtrees of its seeds. Accessed through [obis_eov_seeds()].
#'
#' @format a named list; each element has `label`, `aphiaid`, and `taxon`
#'   (the seed scientific names, in the same order as `aphiaid`).
#' @keywords internal
OBIS_EOV <- list(
  fish = list(
    label   = "Fish",
    aphiaid = c(1829L, 1517375L, 152352L),
    taxon   = c("Agnatha", "Chondrichthyes", "Osteichthyes")),
  hardCorals = list(
    label   = "Hard corals",
    aphiaid = 1363L,
    taxon   = "Scleractinia"),
  mangroves = list(
    label   = "Mangroves",
    aphiaid = c(235048L, 235033L, 234450L, 234495L, 235086L, 235089L, 235091L,
                235106L, 235056L, 235060L, 235045L, 235116L, 235063L, 235072L,
                235075L, 235077L, 235068L, 234488L, 235103L),
    taxon   = c("Combretaceae", "Avicennia", "Nypa", "Bruguiera", "Ceriops",
                "Kandelia", "Rhizophora", "Sonneratia", "Excoecaria", "Pemphis",
                "Camptostemon", "Heritiera", "Xylocarpus", "Osbornia",
                "Pelliciera", "Aegialitis", "Aegiceras", "Acrostichum",
                "Scyphiphora")),
  marineMammals = list(
    label   = "Marine mammals",
    # 477316 (Lutra felina) is the ACCEPTED id; the repo's marineMammals.csv
    # still lists the unaccepted synonym 343992. IdentifierList.csv is correct.
    aphiaid = c(148736L, 2688L, 159502L, 242598L, 477316L, 159017L, 137085L),
    taxon   = c("Pinnipedia", "Cetacea", "Sirenia", "Enhydra lutris",
                "Lutra felina", "Lontra canadensis", "Ursus maritimus")),
  seabirds = list(
    label   = "Seabirds",
    # NB: the EOV seed is class Aves entire, not a seabird-only subset. In a
    # marine-only snapshot that is a reasonable proxy, but it IS all birds.
    aphiaid = 1836L,
    taxon   = "Aves"),
  seagrasses = list(
    label   = "Seagrasses",
    aphiaid = 153491L,
    taxon   = "Alismatales"),
  seaTurtles = list(
    label   = "Sea turtles",
    aphiaid = 987094L,
    taxon   = "Chelonioidea"))

#' Essential Ocean Variable (EOV) taxonomic seeds
#'
#' The root WoRMS AphiaIDs defining each biology & ecosystems EOV, per the IOOS
#' Marine Life Data Network. Expand them to occurrences with [obis_eov_sql()],
#' or to their descendant taxa with [obis_taxon_children()].
#'
#' @param eov optional EOV name(s) to restrict to; default all. One or more of
#'   `"fish"`, `"hardCorals"`, `"mangroves"`, `"marineMammals"`, `"seabirds"`,
#'   `"seagrasses"`, `"seaTurtles"`.
#'
#' @return data frame with one row per seed taxon: `eov`, `label`, `aphiaid`,
#'   `taxon`.
#' @concept eov
#' @export
#' @examples
#' head(obis_eov_seeds())
#' obis_eov_seeds("seaTurtles")
obis_eov_seeds <- function(eov = NULL) {
  nms <- if (is.null(eov)) names(OBIS_EOV) else .obis_eov_names(eov)
  do.call(rbind, lapply(nms, function(k) data.frame(
    eov              = k,
    label            = OBIS_EOV[[k]]$label,
    aphiaid          = OBIS_EOV[[k]]$aphiaid,
    taxon            = OBIS_EOV[[k]]$taxon,
    stringsAsFactors = FALSE)))
}

# validate EOV name(s) against the known set — also the injection guard for the
# only user-supplied string that reaches EOV SQL
.obis_eov_names <- function(eov) {
  if (!is.character(eov) || !length(eov))
    stop("`eov` must be one or more EOV names")
  bad <- setdiff(eov, names(OBIS_EOV))
  if (length(bad))
    stop("unknown EOV: ", paste(bad, collapse = ", "),
         ". Known: ", paste(names(OBIS_EOV), collapse = ", "))
  unique(eov)
}

#' AphiaID seeds for one or more EOVs
#'
#' @param eov EOV name(s); see [obis_eov_seeds()].
#' @return integer vector of seed AphiaIDs (union across the named EOVs).
#' @concept eov
#' @export
obis_eov_aphiaid <- function(eov)
  unique(unlist(lapply(.obis_eov_names(eov),
                       function(k) OBIS_EOV[[k]]$aphiaid), use.names = FALSE))

#' Build an h3t tile SQL query for an Essential Ocean Variable
#'
#' Routes to the precomputed `idx_h3_eov` layer when it can (no year filter,
#' one EOV — as fast as the all-taxa `idx_h3` path), otherwise falls back to a
#' live aggregation over `occ_h3` filtered to the EOV's AphiaID subtree via
#' [obis_h3t_sql()]. Projects exactly `cell_id, value, n`.
#'
#' @param eov EOV name(s); see [obis_eov_seeds()]. Multiple names always take
#'   the live path (the precomputed layer stores one EOV per row).
#' @param indicator one of `"es"` (ES50), `"sp"`, `"shannon"`, `"n"`.
#' @param years optional `c(min, max)` year range; forces the live path.
#' @param esn expected sample size for ES(n); default 50.
#' @param res_max cap on H3 resolution (1-7).
#' @param res_placeholder resolution placeholder; default `"{{res}}"`.
#' @param live force the live `occ_h3` path (e.g. against a store where
#'   [obis_eov_bake()] has not been run). Default: only when it must.
#'
#' @return a SQL string.
#' @concept eov
#' @export
#' @examples
#' obis_eov_sql("seaTurtles")
#' obis_eov_sql("fish", indicator = "n", years = c(2000, 2020))
obis_eov_sql <- function(
  eov,
  indicator       = c("es", "sp", "shannon", "n"),
  years           = NULL,
  esn             = 50L,
  res_max         = 7L,
  res_placeholder = "{{res}}",
  live            = NULL) {

  stopifnot(requireNamespace("glue", quietly = TRUE))
  nms       <- .obis_eov_names(eov)
  indicator <- match.arg(indicator)

  # the precomputed layer holds one EOV per row and no year dimension
  if (is.null(live)) live <- !is.null(years) || length(nms) > 1L

  if (isTRUE(live))
    return(obis_h3t_sql(
      indicator       = indicator,
      aphiaid         = obis_eov_aphiaid(nms),
      years           = years,
      esn             = esn,
      res_max         = res_max,
      res_placeholder = res_placeholder))

  rcap <- max(1L, min(7L, as.integer(res_max)))
  eff  <- glue::glue("LEAST({res_placeholder}, {rcap})")
  col  <- switch(indicator, es = "es", sp = "sp", shannon = "shannon", n = "n")
  as.character(glue::glue(
    "SELECT cell_id, {col} AS value, n FROM idx_h3_eov ",
    "WHERE eov = '{nms}' AND res = {eff}"))
}

# SQL to compute EOV indicators at resolution `r` and INSERT into idx_h3_eov.
# PARITY: the ES(esn) term below is the same translation of calc_indicators() as
# .h3t_idx_sql() / .h3t_idx_taxon_sql() / the `es` branch of obis_h3t_sql() —
# change one, change all four, and keep test-h3t-parity.R + test-eov-parity.R green.
.h3t_idx_eov_sql <- function(eov, r, esn = 50L) {
  glue::glue("
    INSERT INTO idx_h3_eov
    WITH src AS (
      SELECT CAST(h3_cell_to_parent(o.cell_id, {r}) AS BIGINT) AS cell_id,
             o.species, SUM(o.records) AS ni
      FROM occ_h3 o
      JOIN eov e ON o.aphiaid = e.taxonID
      WHERE o.res = {H3T_RES_BASE} AND e.eov = '{eov}'
      GROUP BY 1, 2),
    tot AS (
      SELECT cell_id, SUM(ni) AS n FROM src GROUP BY cell_id),
    per AS (
      SELECT s.cell_id, s.ni, t.n,
        CASE
          WHEN t.n - s.ni >= {esn} THEN 1 - exp(
                 lgamma(t.n - s.ni + 1) + lgamma(t.n - {esn} + 1)
               - lgamma(t.n - s.ni - {esn} + 1) - lgamma(t.n + 1))
          WHEN t.n >= {esn} THEN 1
          ELSE NULL END AS esi
      FROM src s JOIN tot t USING (cell_id))
    SELECT '{eov}' AS eov, {r} AS res, cell_id,
      ANY_VALUE(n)                                       AS n,
      COUNT(*)                                           AS sp,
      -SUM((ni::DOUBLE / n) * ln(ni::DOUBLE / n))        AS shannon,
      SUM((ni::DOUBLE / n) * (ni::DOUBLE / n))           AS simpson,
      SUM(esi)                                           AS es
    FROM per GROUP BY cell_id;")
}

#' Bake the EOV membership and precomputed-indicator layers into a store
#'
#' Adds two tables to an obis_h3 DuckDB store:
#' - `eov` — `(eov, taxonID)` membership, each EOV's seeds expanded to their
#'   full descendant set over the baked WoRMS `taxon` table.
#' - `idx_h3_eov` — precomputed indicators per `(eov, res)` for res 1-7, so an
#'   EOV tile map reads a small clustered lookup instead of re-aggregating
#'   `occ_h3` on every tile.
#'
#' Requires `taxon` (see `data-raw/migrate_add_taxon.R`) and, for complete
#' coverage, a closed taxon tree (see [obis_taxon_fill_gaps()]) — any EOV
#' member whose AphiaID is missing from `taxon` is silently excluded.
#'
#' @param con a `DBI` connection to a **writable** store with `occ_h3` + `taxon`,
#'   with the duckdb `h3` extension loaded.
#' @param eov EOV name(s) to bake; default all.
#' @param esn expected sample size for ES(n); default 50.
#' @param verbose message progress.
#'
#' @return invisibly, a data frame of `eov` and its member-taxon count.
#' @concept eov
#' @export
obis_eov_bake <- function(con, eov = NULL, esn = 50L, verbose = TRUE) {
  stopifnot(requireNamespace("DBI", quietly = TRUE))
  nms <- if (is.null(eov)) names(OBIS_EOV) else .obis_eov_names(eov)

  if (verbose) message("building eov membership from taxon subtrees ...")
  DBI::dbExecute(con, "DROP TABLE IF EXISTS eov;")
  DBI::dbExecute(con, "CREATE TABLE eov (eov VARCHAR, taxonID BIGINT);")
  for (k in nms) {
    cte <- .h3t_taxon_tree_cte(OBIS_EOV[[k]]$aphiaid)
    DBI::dbExecute(con, glue::glue(
      "INSERT INTO eov
       WITH RECURSIVE {cte}
       SELECT DISTINCT '{k}' AS eov, taxonID FROM taxon_tree;"))
  }
  # cluster by the lookup key so an `eov = ...` join prunes to a small scan
  DBI::dbExecute(con, "CREATE TABLE eov_c AS SELECT * FROM eov ORDER BY eov, taxonID;")
  DBI::dbExecute(con, "DROP TABLE eov;")
  DBI::dbExecute(con, "ALTER TABLE eov_c RENAME TO eov;")

  if (verbose) message("computing idx_h3_eov for res ",
                       paste(range(H3T_RES_IDX), collapse = "-"), " ...")
  DBI::dbExecute(con, "DROP TABLE IF EXISTS idx_h3_eov;")
  DBI::dbExecute(con, "
    CREATE TABLE idx_h3_eov (
      eov VARCHAR, res UTINYINT, cell_id BIGINT,
      n BIGINT, sp BIGINT, shannon DOUBLE, simpson DOUBLE, es DOUBLE);")
  for (k in nms)
    for (r in H3T_RES_IDX)
      DBI::dbExecute(con, .h3t_idx_eov_sql(k, r, esn))
  DBI::dbExecute(con, "
    CREATE TABLE idx_h3_eov_c AS SELECT * FROM idx_h3_eov ORDER BY eov, res, cell_id;")
  DBI::dbExecute(con, "DROP TABLE idx_h3_eov;")
  DBI::dbExecute(con, "ALTER TABLE idx_h3_eov_c RENAME TO idx_h3_eov;")

  s <- DBI::dbGetQuery(con, "SELECT eov, COUNT(*) AS n_taxa FROM eov GROUP BY 1 ORDER BY 1")
  if (verbose)
    for (i in seq_len(nrow(s)))
      message("  ", s$eov[i], ": ", format(s$n_taxa[i], big.mark = ","), " taxa")
  invisible(s)
}
