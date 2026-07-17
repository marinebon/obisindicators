# resolve WoRMS taxonomic children (descendants at any rank) and build the
# effort-proxy (SPUE) served SQL. companion to R/h3t.R: the `taxon` table baked
# into the obis_h3 DuckDB store (see data-raw/migrate_add_taxon.R) lets an
# arbitrary-rank filter (e.g. Infraorder Cetacea) resolve to the set of
# descendant AphiaIDs, which then filters the species-level `occ_h3.aphiaid`.
# ported from calcofi4r::get_taxon_children() / cc_match_ichthyo_by_taxon().
# see vignette("taxon_children").

# validate + coerce one or more WoRMS AphiaIDs to integer (also the injection
# guard for the id-list interpolated into recursive-CTE SQL) ----
.h3t_aphiaid_ints <- function(x) {
  ids <- suppressWarnings(as.integer(x))
  if (length(ids) < 1L || anyNA(ids))
    stop("`aphiaid` must be one or more integer WoRMS AphiaIDs")
  unique(ids)
}

# a recursive-CTE fragment `<name> AS ( ... )` yielding every taxonID in the
# subtree rooted at `aphiaid` (the seed ids plus all descendants, walked down
# `taxon.parentNameUsageID`). Returned without the leading `WITH RECURSIVE` so
# callers can splice several CTEs into one `WITH RECURSIVE a AS (...), b AS (...)`.
.h3t_taxon_tree_cte <- function(aphiaid, name = "taxon_tree") {
  ids     <- .h3t_aphiaid_ints(aphiaid)
  id_list <- paste(ids, collapse = ", ")
  glue::glue(
    "{name} AS (
      SELECT taxonID, parentNameUsageID
      FROM taxon
      WHERE taxonID IN ({id_list})
      UNION ALL
      SELECT t.taxonID, t.parentNameUsageID
      FROM taxon t
      JOIN {name} tt ON t.parentNameUsageID = tt.taxonID
      WHERE t.parentNameUsageID IS NOT NULL)")
}

#' Resolve the descendant taxa of a WoRMS AphiaID
#'
#' Recursively walks the WoRMS `taxon` table (baked into the obis_h3 DuckDB
#' store) down `parentNameUsageID` to return the seed taxon plus every
#' descendant, at any rank. This is the local-snapshot replacement for the
#' heavy OBIS `taxonid=` service queries: given e.g. Infraorder Cetacea's
#' AphiaID it returns all its species, whose AphiaIDs then filter `occ_h3`.
#'
#' @param aphiaid one or more integer WoRMS AphiaID(s) (`taxonID`) to root the
#'   subtree at.
#' @param con a `DBI` connection to a DuckDB store exposing a `taxon` table with
#'   columns `taxonID`, `parentNameUsageID`, `acceptedNameUsageID`,
#'   `scientificName`, `taxonRank`.
#'
#' @return data frame with one row per taxon in the subtree: `taxonID`,
#'   `parentNameUsageID`, `acceptedNameUsageID`, `scientificName`, `taxonRank`,
#'   and `depth_level` (0 for the seed, incremented per generation).
#' @concept taxon
#' @export
obis_taxon_children <- function(aphiaid, con) {
  stopifnot(requireNamespace("DBI", quietly = TRUE))
  ids     <- .h3t_aphiaid_ints(aphiaid)
  id_list <- paste(ids, collapse = ", ")
  sql <- glue::glue("
    WITH RECURSIVE taxon_children AS (
      SELECT taxonID, parentNameUsageID, acceptedNameUsageID,
             scientificName, taxonRank, 0 AS depth_level
      FROM taxon
      WHERE taxonID IN ({id_list})
      UNION ALL
      SELECT t.taxonID, t.parentNameUsageID, t.acceptedNameUsageID,
             t.scientificName, t.taxonRank, tc.depth_level + 1 AS depth_level
      FROM taxon t
      JOIN taxon_children tc ON t.parentNameUsageID = tc.taxonID
      WHERE t.parentNameUsageID IS NOT NULL)
    SELECT * FROM taxon_children
    ORDER BY depth_level, taxonRank, scientificName")
  DBI::dbGetQuery(con, sql)
}

#' Standalone SQL for the AphiaID subtree (descendant taxonIDs)
#'
#' Wraps [obis_taxon_children()]'s recursive walk as a self-contained
#' read-only `SELECT` returning the distinct descendant `taxonID`s. Handy for
#' the API and for composing an `aphiaid IN (...)` filter.
#'
#' @param aphiaid one or more integer WoRMS AphiaID(s).
#' @return a SQL string: `WITH RECURSIVE taxon_tree AS (...) SELECT DISTINCT taxonID ...`.
#' @concept taxon
#' @export
obis_taxon_subtree_sql <- function(aphiaid) {
  cte <- .h3t_taxon_tree_cte(aphiaid)
  as.character(glue::glue(
    "WITH RECURSIVE {cte}\nSELECT DISTINCT taxonID FROM taxon_tree"))
}

#' Sightings-per-unit-effort (SPUE) effort proxy, per H3 cell (R reference)
#'
#' Presence-only effort proxy: within the spatial footprint of a higher-order
#' "effort" taxon (e.g. all Cetacea, from multi-species surveys), the fraction
#' of records that are the target taxon. `spue = n_num / n_den` where the
#' denominator is every record of the effort subtree in the cell and the
#' numerator is the subset that are the target subtree. This is the pure-R
#' reference pinned to [obis_spue_sql()] by the package tests.
#'
#' @param df data frame of species-level records with columns `cell`,
#'   `aphiaid`, `records` (as in `occ_h3`).
#' @param num_aphiaid integer AphiaIDs of the **target** subtree (already
#'   resolved via [obis_taxon_children()]).
#' @param den_aphiaid integer AphiaIDs of the **effort** subtree (denominator).
#'
#' @return data frame with `cell`, `n_num`, `n_den`, `spue`; only cells with
#'   effort records (`n_den > 0`) are returned.
#' @concept taxon
#' @export
calc_spue <- function(df, num_aphiaid, den_aphiaid) {
  stopifnot(is.data.frame(df),
            all(c("cell", "aphiaid", "records") %in% names(df)))
  num <- unique(as.integer(num_aphiaid))
  den <- unique(as.integer(den_aphiaid))

  df %>%
    filter(aphiaid %in% den) %>%          # restrict to the effort footprint
    group_by(cell) %>%
    summarize(
      n_num = sum(records[aphiaid %in% num]),
      n_den = sum(records),
      .groups = "drop") %>%
    mutate(spue = n_num / n_den)
}

#' Build an h3t tile SQL query for the SPUE effort proxy
#'
#' Live per-cell `value = records(target subtree) / records(effort subtree)`,
#' restricted to the effort taxon's footprint. Both subtrees are resolved with
#' recursive CTEs over the baked `taxon` table, so this works for arbitrary
#' ranks. Projects exactly `cell_id, value, n` (with `n` = effort record count),
#' as the `h3t` service requires. See [calc_spue()] for the pinned R reference.
#'
#' @param num_aphiaid target-taxon AphiaID(s) (numerator subtree).
#' @param den_aphiaid effort-taxon AphiaID(s) (denominator subtree); typically a
#'   higher-order taxon such as the target's parent class.
#' @param res_max cap on H3 resolution (1-7); see [obis_h3t_sql()].
#' @param res_placeholder resolution placeholder; default `"{{res}}"`.
#' @param bbox_placeholder spatial-prune placeholder spliced into the `occ_h3`
#'   scan; default `"{{bbox}}"` (the `h3t` server substitutes a per-tile
#'   `lat`/`lng` predicate). Pass `""` to disable for direct execution — see
#'   [obis_h3t_sql()].
#'
#' @return a SQL string.
#' @concept taxon
#' @export
obis_spue_sql <- function(
  num_aphiaid,
  den_aphiaid,
  res_max          = 7L,
  res_placeholder  = "{{res}}",
  bbox_placeholder = "{{bbox}}") {

  stopifnot(requireNamespace("glue", quietly = TRUE))
  r    <- res_placeholder
  bp   <- bbox_placeholder                 # spliced as a var so glue keeps "{{bbox}}"
  rcap <- max(1L, min(7L, as.integer(res_max)))
  eff  <- glue::glue("LEAST({r}, {rcap})")
  tier <- glue::glue("CASE WHEN {eff} <= 3 THEN 3 WHEN {eff} <= 5 THEN 5 ELSE 7 END")

  num_cte <- .h3t_taxon_tree_cte(num_aphiaid, "num_tree")
  den_cte <- .h3t_taxon_tree_cte(den_aphiaid, "den_tree")

  as.character(glue::glue("
    WITH RECURSIVE {num_cte},
    {den_cte},
    src AS (
      SELECT CAST(h3_cell_to_parent(cell_id, {eff}) AS BIGINT) AS cell_id,
             -- COALESCE so an effort cell lacking the target reads 0, not NULL
             -- (matches calc_spue(): sum of no records is 0). presence-only:
             -- the target was absent *despite* effort here.
             COALESCE(SUM(records) FILTER (WHERE aphiaid IN (SELECT taxonID FROM num_tree)), 0) AS n_num,
             SUM(records) AS n_den
      FROM occ_h3
      WHERE res = {tier}
        AND aphiaid IN (SELECT taxonID FROM den_tree)
        {bp}
      GROUP BY 1)
    SELECT cell_id,
           n_num::DOUBLE / NULLIF(n_den, 0) AS value,
           n_den AS n
    FROM src"))
}
