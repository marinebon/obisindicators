# fill gaps in the baked WoRMS `taxon` table from the WoRMS REST API.
#
# the bulk `taxon.txt` download (see data-raw/build_taxon_parquet.R) is not a
# complete cover of the AphiaIDs OBIS actually carries — notably for algae,
# whose WoRMS records come from separate thematic databases that the DwC export
# lags. Any aphiaid in `occ_h3` that is missing from `taxon` is invisible to the
# recursive children walk (R/taxon.R), so its records silently drop out of every
# `obis_h3t_sql(aphiaid=)` / EOV / SPUE query.
#
# the fix is bulk-join-then-supplement: keep the fast bulk download as the base,
# then look up only the missing ids individually via the WoRMS REST API. This is
# the same pattern as msens::wm_rest() (parallel, paged httr2 requests) and
# calcofi4r::get_taxon_children(), reduced to the one operation needed here.
#
# gap-filling must run to *transitive closure*: inserting an orphan species is
# not enough, because the walk descends `parentNameUsageID` from a seed. If the
# orphan's parent (or grandparent, ...) is also missing, the orphan stays
# disconnected from the tree and is still unreachable. So each round also fetches
# any newly-referenced ancestor that is itself absent, until nothing new appears.

# WoRMS REST defaults ----
WORMS_REST_SERVER <- "https://www.marinespecies.org/rest"
# AphiaRecordsByAphiaIDs pages at 50 ids per request (msens::wm_rest_params)
WM_MAX_IDS        <- 50L

# the columns the recursive walk needs, mapped from the WoRMS REST field names
WM_FIELD_MAP <- c(
  taxonID             = "AphiaID",
  parentNameUsageID   = "parentNameUsageID",
  acceptedNameUsageID = "valid_AphiaID",
  scientificName      = "scientificname",
  taxonRank           = "rank",
  taxonomicStatus     = "status")

# pull one field out of a parsed WoRMS record list, NA when absent/null
.wm_field <- function(rec, nm, as_int = FALSE) {
  v <- rec[[nm]]
  if (is.null(v) || length(v) != 1L) return(if (as_int) NA_integer_ else NA_character_)
  if (as_int) suppressWarnings(as.integer(v)) else as.character(v)
}

#' Look up WoRMS taxon records by AphiaID
#'
#' Batched, parallel calls to the WoRMS REST `AphiaRecordsByAphiaIDs` operation,
#' returning exactly the columns the baked `taxon` table carries. This is the
#' per-id supplement to the bulk `taxon.txt` download — see
#' [obis_taxon_fill_gaps()], which drives it.
#'
#' Ids WoRMS has no record for are simply absent from the result (the API
#' returns a positional `null` for them, or HTTP 204 when a whole batch misses),
#' so `setdiff(aphiaid, out$taxonID)` gives the unresolvable ids.
#'
#' @param aphiaid integer WoRMS AphiaID(s) to look up.
#' @param server WoRMS REST base URL; default `"https://www.marinespecies.org/rest"`.
#' @param batch_size ids per request (WoRMS caps this operation at 50).
#' @param concurrency max parallel requests; kept low by default to stay polite
#'   to a shared public service.
#' @param verbose message progress per round of requests.
#'
#' @return data frame with `taxonID`, `parentNameUsageID`, `acceptedNameUsageID`,
#'   `scientificName`, `taxonRank`, `taxonomicStatus`; zero rows if nothing matched.
#' @concept taxon
#' @export
wm_aphia_records <- function(
  aphiaid,
  server      = WORMS_REST_SERVER,
  batch_size  = WM_MAX_IDS,
  concurrency = 4L,
  verbose     = TRUE) {

  if (!requireNamespace("httr2", quietly = TRUE))
    stop("`httr2` is required for WoRMS lookups; install it or pass your own `fetch`")

  ids <- .h3t_aphiaid_ints(aphiaid)
  bs  <- max(1L, min(as.integer(batch_size), WM_MAX_IDS))
  grp <- split(ids, ceiling(seq_along(ids) / bs))
  if (verbose)
    message("  WoRMS: ", length(ids), " id(s) in ", length(grp), " request(s)")

  reqs <- lapply(grp, function(g) {
    httr2::request(server) |>
      httr2::req_url_path_append("AphiaRecordsByAphiaIDs") |>
      httr2::req_url_query(`aphiaids[]` = g, .multi = "explode") |>
      httr2::req_retry(max_tries = 3L) |>
      httr2::req_timeout(60L)
  })

  resps <- do.call(
    httr2::req_perform_parallel,
    .wm_parallel_args(reqs, max(1L, as.integer(concurrency))))

  recs <- unlist(lapply(resps, function(r) {
    # a failed request (or 204 No Content) contributes nothing; the ids simply
    # stay unresolved rather than aborting the whole fill
    if (inherits(r, "error") || is.null(r)) return(list())
    if (httr2::resp_status(r) != 200L)      return(list())
    body <- tryCatch(httr2::resp_body_json(r), error = function(e) list())
    Filter(Negate(is.null), body)
  }), recursive = FALSE)

  if (!length(recs))
    return(.wm_empty_taxon_df())

  out <- data.frame(
    taxonID             = vapply(recs, .wm_field, integer(1),   WM_FIELD_MAP[["taxonID"]],             as_int = TRUE),
    parentNameUsageID   = vapply(recs, .wm_field, integer(1),   WM_FIELD_MAP[["parentNameUsageID"]],   as_int = TRUE),
    acceptedNameUsageID = vapply(recs, .wm_field, integer(1),   WM_FIELD_MAP[["acceptedNameUsageID"]], as_int = TRUE),
    scientificName      = vapply(recs, .wm_field, character(1), WM_FIELD_MAP[["scientificName"]]),
    taxonRank           = vapply(recs, .wm_field, character(1), WM_FIELD_MAP[["taxonRank"]]),
    taxonomicStatus     = vapply(recs, .wm_field, character(1), WM_FIELD_MAP[["taxonomicStatus"]]),
    stringsAsFactors    = FALSE)

  out <- out[!is.na(out$taxonID), , drop = FALSE]
  out[!duplicated(out$taxonID), , drop = FALSE]
}

# httr2 renamed the concurrency control: >= 1.1 takes `max_active`, earlier
# versions cap it on a curl `pool`. Build whichever the INSTALLED version
# accepts, so the same code runs against the older httr2 pinned in the msens
# plumber container (1.0.5) as on a current laptop.
.wm_parallel_args <- function(reqs, concurrency,
                              fn = httr2::req_perform_parallel) {
  fmls <- names(formals(fn))
  args <- list(reqs)
  if ("max_active" %in% fmls) {
    args$max_active <- concurrency
  } else if ("pool" %in% fmls) {
    args$pool <- curl::new_pool(total_con = concurrency, host_con = concurrency)
  }
  if ("on_error" %in% fmls) args$on_error <- "continue"
  args
}

.wm_empty_taxon_df <- function()
  data.frame(
    taxonID             = integer(0),
    parentNameUsageID   = integer(0),
    acceptedNameUsageID = integer(0),
    scientificName      = character(0),
    taxonRank           = character(0),
    taxonomicStatus     = character(0),
    stringsAsFactors    = FALSE)

#' AphiaIDs present in `occ_h3` but missing from the `taxon` table
#'
#' The reachability gap: these occurrences cannot be found by any
#' [obis_taxon_children()] walk, so they are silently excluded from every
#' `aphiaid`-filtered indicator, EOV and SPUE query. Feed the result to
#' [obis_taxon_fill_gaps()].
#'
#' @param con a `DBI` connection to a store with `occ_h3` and `taxon`.
#' @param min_records only report orphans with at least this many records.
#'
#' @return data frame of `taxonID` and `records`, most records first.
#' @concept taxon
#' @export
obis_taxon_orphans <- function(con, min_records = 0L) {
  stopifnot(requireNamespace("DBI", quietly = TRUE))
  # occ_h3 stores the same records rolled up at several resolution tiers, so
  # count at one tier only (the coarsest = fewest rows) to avoid multiplying
  DBI::dbGetQuery(con, glue::glue("
    WITH tier AS (SELECT MIN(res) AS res FROM occ_h3)
    SELECT aphiaid AS taxonID, SUM(records) AS records
    FROM occ_h3
    WHERE res = (SELECT res FROM tier)
      AND aphiaid IS NOT NULL
      AND aphiaid NOT IN (SELECT taxonID FROM taxon)
    GROUP BY 1
    HAVING SUM(records) >= {as.integer(min_records)}
    ORDER BY records DESC"))
}

# ids referenced as a parent/accepted-name by some row of `taxon` but absent as
# a `taxonID` — the dangling edges that leave a filled-in orphan disconnected
.obis_taxon_dangling <- function(con, include_accepted = TRUE) {
  cols <- c("parentNameUsageID",
            if (isTRUE(include_accepted)) "acceptedNameUsageID")
  cols <- intersect(cols, DBI::dbListFields(con, "taxon"))
  if (!length(cols)) return(integer(0))
  sel <- paste(glue::glue(
    "SELECT {cols} AS id FROM taxon WHERE {cols} IS NOT NULL"), collapse = "\n    UNION\n    ")
  d <- DBI::dbGetQuery(con, glue::glue("
    SELECT DISTINCT id FROM (
    {sel}
    ) WHERE id NOT IN (SELECT taxonID FROM taxon)"))
  as.integer(d$id)
}

#' Fill gaps in the `taxon` table from the WoRMS REST API
#'
#' Supplements the bulk WoRMS `taxon.txt` download with per-id lookups for every
#' AphiaID that `occ_h3` carries but `taxon` lacks, then keeps going until the
#' tree is *closed*: each round also fetches any ancestor newly referenced by the
#' rows just inserted. Without that closure an orphan species stays disconnected
#' from its seed and remains unreachable by [obis_taxon_children()].
#'
#' Writes to `con`, so open the store read-write (see
#' `data-raw/migrate_fill_taxon_gaps.R`, which copies first).
#'
#' @param con a `DBI` connection to a **writable** store with `occ_h3` + `taxon`.
#' @param fetch function taking an integer vector of AphiaIDs and returning a
#'   data frame shaped like [wm_aphia_records()]'s output; the seam that lets
#'   tests run without network.
#' @param max_rounds runaway guard on closure rounds. Each round climbs exactly
#'   one generation, and a full WoRMS chain (every intermediate rank from species
#'   to Biota) runs ~15-20 deep, so this needs headroom well past the depth of
#'   the *named* ranks. If the guard is hit while ancestors are still missing the
#'   fill warns and reports `closed = FALSE` rather than leaving you to believe
#'   the tree is whole.
#' @param min_records only chase orphans with at least this many records.
#' @param verbose message per-round progress.
#'
#' @return invisibly, a list with `added` (data frame of inserted rows),
#'   `unresolved` (AphiaIDs WoRMS had no record for), `rounds`,
#'   `records_recovered` (occurrence records made reachable by the fill), and
#'   `closed` (did the ancestor walk reach closure within `max_rounds`).
#' @concept taxon
#' @export
obis_taxon_fill_gaps <- function(
  con,
  fetch       = wm_aphia_records,
  max_rounds  = 40L,
  min_records = 0L,
  verbose     = TRUE) {

  stopifnot(requireNamespace("DBI", quietly = TRUE))
  taxon_cols <- DBI::dbListFields(con, "taxon")

  orphans <- obis_taxon_orphans(con, min_records = min_records)
  recovered <- sum(as.numeric(orphans$records))
  if (verbose)
    message("gap-fill: ", nrow(orphans), " orphan aphiaid(s) in occ_h3 covering ",
            format(recovered, big.mark = ","), " records")

  todo       <- as.integer(orphans$taxonID)
  unresolved <- integer(0)
  added      <- .wm_empty_taxon_df()

  round  <- 0L
  closed <- FALSE
  while (round < as.integer(max_rounds)) {
    todo <- setdiff(todo, c(added$taxonID, unresolved))
    if (!length(todo)) { closed <- TRUE; break }
    round <- round + 1L
    if (verbose) message(" round ", round, ": fetching ", length(todo), " id(s)")

    got <- fetch(todo)
    # ids WoRMS has no record for: remember them so later rounds don't retry
    unresolved <- union(unresolved, setdiff(todo, got$taxonID))

    got <- got[!got$taxonID %in% added$taxonID, , drop = FALSE]
    if (nrow(got)) {
      .obis_taxon_insert(con, got, taxon_cols)
      added <- rbind(added, got)
    }
    # close the tree: chase ancestors the new rows point at but that are absent
    todo <- setdiff(.obis_taxon_dangling(con), unresolved)
  }

  # a partial climb leaves rows whose parent is still absent, so a walk seeded
  # above the break never reaches them — say so instead of implying completeness
  dangling <- setdiff(.obis_taxon_dangling(con), unresolved)
  if (!closed || length(dangling))
    warning("gap-fill stopped after ", round, " round(s) with ", length(dangling),
            " ancestor(s) still missing — the taxon tree is NOT closed; ",
            "re-run with a larger `max_rounds`", call. = FALSE)

  left <- nrow(obis_taxon_orphans(con, min_records = min_records))
  if (verbose)
    message("gap-fill: added ", nrow(added), " taxon row(s); ",
            length(unresolved), " id(s) unresolved by WoRMS; ",
            left, " orphan(s) remain; tree closed: ",
            !length(dangling) && closed)

  invisible(list(
    added             = added,
    unresolved        = unresolved,
    rounds            = round,
    records_recovered = recovered,
    closed            = closed && !length(dangling)))
}

# insert a fetched data frame into `taxon`, projecting to whatever columns the
# target table actually has (build_taxon_parquet.R writes 6; older/test stores 5)
.obis_taxon_insert <- function(con, df, taxon_cols) {
  keep <- intersect(taxon_cols, names(df))
  tmp  <- paste0("taxon_gapfill_", as.integer(nrow(df)), "_tmp")
  DBI::dbWriteTable(con, tmp, df[, keep, drop = FALSE],
                    temporary = TRUE, overwrite = TRUE)
  on.exit(try(DBI::dbRemoveTable(con, tmp), silent = TRUE), add = TRUE)
  cols <- paste(sprintf('"%s"', keep), collapse = ", ")
  DBI::dbExecute(con, glue::glue(
    "INSERT INTO taxon ({cols}) SELECT {cols} FROM {tmp}
     WHERE taxonID NOT IN (SELECT taxonID FROM taxon)"))
}
