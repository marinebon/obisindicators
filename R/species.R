# the species x hex x count table of the obis-h3 release: which species were
# recorded in a cell and how often, so a browser (DuckDB-WASM) can answer a WoRMS
# subtree or a cell itself instead of asking the h3t service. sized and checked
# against h3t in spike 2 (2026-10-22): partitioned by class, sorted by
# (cell_id, aphiaid), one file per partition, a lineage array per species.

# the columns of a species file and of the lookup, documented in release.json ----
SPECIES_COLUMNS <- list(
  list(name = "h3",       type = "VARCHAR", description = "H3 cell index as a lowercase hex string"),
  list(name = "cell_id",  type = "BIGINT",  description = "H3 cell index as BIGINT (same cell as h3); rows are sorted by cell_id, aphiaid"),
  list(name = "name_key", type = "INTEGER", description = "dense integer per distinct species name (the lookup's name_key); richness counts names, as h3t does"),
  list(name = "aphiaid",  type = "BIGINT",  description = "WoRMS AphiaID of the occurrences (as recorded, accepted or not)"),
  list(name = "n",        type = "BIGINT",  description = "number of occurrence records of this aphiaid in this cell"))

SPECIES_LOOKUP_COLUMNS <- list(
  list(name = "aphiaid",  type = "BIGINT",   description = "WoRMS AphiaID, one row each"),
  list(name = "name_key", type = "INTEGER",  description = "dense integer per distinct species name, ordered by name"),
  list(name = "species",  type = "VARCHAR",  description = "species name as OBIS records it"),
  list(name = "genus",    type = "VARCHAR",  description = "genus (OBIS)"),
  list(name = "family",   type = "VARCHAR",  description = "family (OBIS)"),
  list(name = "order",    type = "VARCHAR",  description = "order (OBIS)"),
  list(name = "class",    type = "VARCHAR",  description = "class (OBIS); the partition key of the species files (_none when NULL)"),
  list(name = "phylum",   type = "VARCHAR",  description = "phylum (OBIS)"),
  list(name = "lineage",  type = "BIGINT[]", description = "the aphiaid itself, then its ancestors up taxon.parentNameUsageID (self first); a taxon filter is list_contains(lineage, <aphiaid>)"),
  list(name = "records",  type = "BIGINT",   description = "number of occurrence records of this aphiaid"))

# the hive value of a partition key on disk: NULL becomes `null_value` (DuckDB-WASM
# reads __HIVE_DEFAULT_PARTITION__ as a string, so a NULL partition is spelled out),
# anything outside [A-Za-z0-9._~-] is percent-encoded, which DuckDB decodes on read
.obis_hive_value <- function(x, null_value = "_none") {
  x <- as.character(x)
  vapply(x, function(v) {
    if (is.na(v)) return(null_value)
    utils::URLencode(enc2utf8(v), reserved = TRUE)
  }, character(1), USE.NAMES = FALSE)
}

#' SQL for the species x hex x count table at one resolution
#'
#' One row per (cell, aphiaid) from the store's `occ_h3`, with `n` the number
#' of records. A resolution that is an `occ_h3` tier (3, 5, 7) reads that tier;
#' any other is rolled up from the next finer tier with `h3_cell_to_parent()`
#' (res 4 from the res-5 tier, as in the decade layers). Rows with a NULL
#' `aphiaid` are left out (no taxon filter can reach them).
#'
#' With `lookup`, the name of a table holding [obis_h3_species_lookup_sql()]'s
#' rows, the result has the columns of a species file plus the partition key:
#' `h3 VARCHAR, cell_id BIGINT, name_key INTEGER, aphiaid BIGINT, n BIGINT,
#' class VARCHAR` (the lookup's class, so one aphiaid always lands in one
#' partition). Without it, `cell_id, aphiaid, n`.
#'
#' @param res H3 resolution, 1 to 7.
#' @param from the species-level table (default `"occ_h3"`).
#' @param lookup optional name of the lookup table to join (see above).
#' @param decade per decade (`decade = floor(date_year / 10) * 10`, records with
#'   a year only) instead of over all years (default FALSE).
#' @param decades with `decade = TRUE`, the decades to keep (default NULL: all).
#' @return a SQL string (a SELECT).
#' @concept store
#' @export
#' @examples
#' cat(obis_h3_species_sql(4))
obis_h3_species_sql <- function(res, from = "occ_h3", lookup = NULL, decade = FALSE,
                                decades = NULL) {
  res <- as.integer(res)
  stopifnot(length(res) == 1L, res %in% H3T_RES_IDX,
            is.character(from), length(from) == 1L, is.logical(decade))
  tier <- .obis_tier(res)
  cell <- if (tier == res) "cell_id" else
    glue::glue("CAST(h3_cell_to_parent(cell_id, {res}) AS BIGINT)")
  dec  <- "CAST(floor(date_year / 10) * 10 AS INTEGER)"
  key  <- if (decade) glue::glue("{dec} AS decade, ") else ""
  filt <- if (decade) " AND date_year IS NOT NULL" else ""
  if (decade && !is.null(decades))
    filt <- glue::glue("{filt} AND {dec} IN ({paste(as.integer(decades), collapse = ', ')})")
  agg <- glue::glue("
    SELECT {key}{cell} AS cell_id, aphiaid::BIGINT AS aphiaid, SUM(records)::BIGINT AS n
    FROM {from}
    WHERE res = {tier} AND aphiaid IS NOT NULL{filt}
    GROUP BY ALL")
  if (is.null(lookup)) return(agg)
  dk <- if (decade) "s.decade, " else ""
  glue::glue("
    SELECT {dk}lower(printf('%x', s.cell_id)) AS h3, s.cell_id, l.name_key, s.aphiaid, s.n, l.class
    FROM ({agg}) s
    JOIN {lookup} l USING (aphiaid)")
}

#' SQL for the species lookup of the species x hex x count table
#'
#' One row per aphiaid in `occ_h3`: `aphiaid BIGINT, name_key INTEGER, species,
#' genus, family, "order", class, phylum, lineage BIGINT[], records BIGINT`.
#'
#' `name_key` is a dense integer per distinct species name (ordered by name):
#' richness counts species *names*, as h3t and `.h3t_indicators_sql()` group by
#' `occ_h3.species`, and some names carry several aphiaids (2,140 in the
#' 2026-10 global store), so counting aphiaids would overstate `sp`.
#'
#' `lineage` is the aphiaid itself followed by its ancestors, walked up
#' `taxon.parentNameUsageID` from the occurrence's own aphiaid (accepted or
#' not), so `list_contains(lineage, A)` selects exactly the aphiaids the
#' recursive CTE of h3t / [obis_taxon_children()] finds walking down from `A`.
#' A synonym keeps its own parent chain, not its accepted name's. Without a
#' taxon table (`taxon = NULL`) the lineage is the aphiaid alone. The rank
#' columns and the name are taken once per aphiaid (`MIN`, so a NULL class is
#' replaced by a named one if both occur); `records` is summed over the
#' coarsest `occ_h3` tier.
#'
#' @param from the species-level table (default `"occ_h3"`).
#' @param taxon the WoRMS taxon table (`taxonID`, `parentNameUsageID`), or NULL.
#' @param max_depth guard against a cycle in the taxonomy (default 64).
#' @return a SQL string (a SELECT, ordered by aphiaid).
#' @concept store
#' @export
#' @examples
#' cat(obis_h3_species_lookup_sql())
obis_h3_species_lookup_sql <- function(from = "occ_h3", taxon = "taxon", max_depth = 64L) {
  stopifnot(is.character(from), length(from) == 1L,
            is.null(taxon) || (is.character(taxon) && length(taxon) == 1L))
  sp <- glue::glue('
    sp AS (
      SELECT aphiaid::BIGINT AS aphiaid, MIN(species) AS species, MIN(genus) AS genus,
             MIN(family) AS family, MIN("order") AS "order", MIN(class) AS class,
             MIN(phylum) AS phylum, SUM(records)::BIGINT AS records
      FROM {from}
      WHERE res = (SELECT MIN(res) FROM {from}) AND aphiaid IS NOT NULL
      GROUP BY 1)')
  if (is.null(taxon)) {
    with <- glue::glue("WITH {sp},
    lin AS (SELECT aphiaid, [aphiaid]::BIGINT[] AS lineage FROM sp)")
  } else {
    with <- glue::glue("WITH RECURSIVE {sp},
    up AS (
      SELECT aphiaid, aphiaid AS node, 0 AS depth FROM sp
      UNION ALL
      SELECT up.aphiaid, t.parentNameUsageID::BIGINT AS node, up.depth + 1 AS depth
      FROM up JOIN {taxon} t ON t.taxonID = up.node
      WHERE t.parentNameUsageID IS NOT NULL AND t.parentNameUsageID <> t.taxonID
        AND up.depth < {as.integer(max_depth)}),
    lin AS (SELECT aphiaid, list(node ORDER BY depth)::BIGINT[] AS lineage FROM up GROUP BY aphiaid)")
  }
  glue::glue('{with}
    SELECT sp.aphiaid, (dense_rank() OVER (ORDER BY sp.species))::INTEGER AS name_key,
           sp.species, sp.genus, sp.family, sp."order", sp.class, sp.phylum,
           lin.lineage, sp.records
    FROM sp JOIN lin USING (aphiaid)
    ORDER BY sp.aphiaid')
}

#' The pre-aggregated heads the species table still needs
#'
#' A subtree inside one class reads one class file of the species table plus
#' the `_none` file; a taxon spanning several classes reads them all, which for
#' Animalia at res 4 is slower than h3t (spike 2, 2026-10-22). Those taxa get a
#' pre-aggregated head (an indicator layer like `all`): the release already
#' has the heads all, EOV and phylum to family (the `taxon` layer); this lists
#' the ones to add, Animalia (aphiaid 2) and every taxon whose subtree spans
#' two or more *named* classes (the lookup's `class`, NULLs not counted).
#' Only taxa that occur in some lineage are listed.
#'
#' @param con a DBI connection.
#' @param lookup the table (or a parenthesised SELECT) with the lookup rows of
#'   [obis_h3_species_lookup_sql()].
#' @param taxon the WoRMS taxon table for names and ranks (NULL: no names).
#' @param min_classes the number of named classes that makes a head (default 2).
#' @param include aphiaids always listed when present (default 2, Animalia).
#' @return a data frame ordered by aphiaid: `aphiaid, name, rank, n_classes`
#'   (named classes spanned), `n_species` (aphiaids in the subtree),
#'   `records`, `reason` (`"included"` for `include`, else `"multi_class"`).
#' @concept store
#' @export
obis_h3_species_heads <- function(con, lookup = "species_lookup", taxon = "taxon",
                                  min_classes = 2L, include = 2L) {
  stopifnot(requireNamespace("DBI", quietly = TRUE))
  inc <- .h3t_aphiaid_ints(include)
  nm  <- if (is.null(taxon)) "NULL::VARCHAR AS name, NULL::VARCHAR AS rank" else
    "t.scientificName AS name, t.taxonRank AS rank"
  jn  <- if (is.null(taxon)) "" else glue::glue("LEFT JOIN {taxon} t ON t.taxonID = g.aphiaid")
  DBI::dbGetQuery(con, glue::glue("
    WITH u AS (
      SELECT unnest(lineage) AS node, aphiaid, class, records FROM {lookup}),
    g AS (
      SELECT node AS aphiaid, COUNT(DISTINCT class)::INTEGER AS n_classes,
             COUNT(DISTINCT aphiaid)::INTEGER AS n_species, SUM(records)::DOUBLE AS records
      FROM u GROUP BY node)
    SELECT g.aphiaid::DOUBLE AS aphiaid, {nm}, g.n_classes, g.n_species, g.records,
           CASE WHEN g.aphiaid IN ({paste(inc, collapse = ', ')}) THEN 'included'
                ELSE 'multi_class' END AS reason
    FROM g {jn}
    WHERE g.n_classes >= {as.integer(min_classes)} OR g.aphiaid IN ({paste(inc, collapse = ', ')})
    ORDER BY g.aphiaid"))
}

#' Write a query to one Parquet file per partition, sorted
#'
#' The explicit per-partition writer of the species table. DuckDB's
#' `COPY ... PARTITION_BY` wrote thousands of files per resolution for 301
#' classes and lost the sort order (spike 2), so this materializes `sql` once,
#' then runs one `COPY` per partition value to
#' `dir/<key>=<value>[/<key2>=<value2>]/data_0.parquet`, each `ORDER BY order_by`
#' with fixed row groups, so a reader finds a cell's rows in one row group from
#' the `cell_id` statistics. A NULL partition value is written as `null_value`
#' (`_none`; DuckDB-WASM reads `__HIVE_DEFAULT_PARTITION__` as a string), and
#' other values are percent-encoded where needed (DuckDB decodes them on read).
#' The partition columns are left out of the files (they are in the path).
#'
#' @param con a DBI connection to DuckDB.
#' @param sql a SELECT yielding the partition columns and the file columns.
#' @param dir output directory (created).
#' @param partition_by the partition column(s), outermost first (default `"class"`).
#' @param order_by the sort columns within a file (default `c("cell_id", "aphiaid")`).
#' @param null_value the on-disk value of a NULL partition (default `"_none"`).
#' @param compression Parquet codec (default `"zstd"`).
#' @param row_group_size rows per row group (default 100000; DuckDB rounds up
#'   to a multiple of 2048).
#' @return a data frame, one row per partition: the partition columns, `path`
#'   (relative to `dir`) and `rows`.
#' @concept store
#' @export
obis_h3_write_partitions <- function(
  con, sql, dir,
  partition_by   = "class",
  order_by       = c("cell_id", "aphiaid"),
  null_value     = "_none",
  compression    = "zstd",
  row_group_size = 100000L) {

  stopifnot(
    requireNamespace("DBI", quietly = TRUE),
    is.character(partition_by), length(partition_by) >= 1L,
    is.character(order_by),
    is.character(null_value), length(null_value) == 1L, nzchar(null_value),
    grepl("^[A-Za-z0-9]+$", compression),
    is.numeric(row_group_size), row_group_size >= 1)
  q   <- function(x) gsub("'", "''", x)
  tmp <- "_obis_write_partitions"
  pb  <- paste(sprintf('"%s"', partition_by), collapse = ", ")
  ob  <- paste(sprintf('"%s"', order_by), collapse = ", ")
  DBI::dbExecute(con, glue::glue(
    "CREATE OR REPLACE TEMP TABLE {tmp} AS SELECT * FROM ({sql}) _s ORDER BY {pb}, {ob};"))
  on.exit(DBI::dbExecute(con, glue::glue("DROP TABLE IF EXISTS {tmp};")), add = TRUE)

  ty   <- DBI::dbGetQuery(con, glue::glue("DESCRIBE {tmp}"))
  stopifnot(all(c(partition_by, order_by) %in% ty$column_name))
  cols <- paste(sprintf('"%s"', setdiff(ty$column_name, partition_by)), collapse = ", ")
  is_chr <- setNames(grepl("^VARCHAR", ty$column_type), ty$column_name)[partition_by]

  parts <- DBI::dbGetQuery(con, glue::glue(
    "SELECT {pb}, COUNT(*)::DOUBLE AS rows FROM {tmp} GROUP BY ALL ORDER BY ALL"))
  for (p in partition_by[is_chr])
    if (any(parts[[p]] %in% null_value, na.rm = TRUE))
      stop("a ", p, " value equals null_value '", null_value, "'")

  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  parts$path <- character(nrow(parts))
  for (i in seq_len(nrow(parts))) {
    segs <- character(0); conds <- character(0)
    for (p in partition_by) {
      v <- parts[[p]][i]
      segs <- c(segs, paste0(p, "=", .obis_hive_value(v, null_value)))
      conds <- c(conds, if (is.na(v)) sprintf('"%s" IS NULL', p) else if (is_chr[[p]])
        sprintf('"%s" = %s', p, .h3t_sql_quote(v)) else sprintf('"%s" = %s', p, format(v, scientific = FALSE)))
    }
    rel <- file.path(paste(segs, collapse = "/"), "data_0.parquet")
    dir.create(file.path(dir, dirname(rel)), recursive = TRUE, showWarnings = FALSE)
    DBI::dbExecute(con, glue::glue(
      "COPY (SELECT {cols} FROM {tmp} WHERE {paste(conds, collapse = ' AND ')} ORDER BY {ob})
       TO '{q(file.path(dir, rel))}'
       (FORMAT PARQUET, COMPRESSION {compression}, ROW_GROUP_SIZE {as.integer(row_group_size)});"))
    parts$path[i] <- rel
  }
  parts[, c(partition_by, "path", "rows"), drop = FALSE]
}

#' SQL for a WoRMS subtree's indicators from the exported species table
#'
#' What a browser runs against the release instead of asking h3t: the species
#' files of one resolution joined to the lookup, filtered to the aphiaids whose
#' `lineage` contains a seed, and summarized per cell with the store's own
#' indicator SQL (`.h3t_indicators_sql()`, species counted by `name_key`). It
#' reproduces the h3t subtree (the recursive CTE down `taxon` from the seeds)
#' cell for cell: `n` and `sp` exactly, Shannon, Simpson and ES to floating
#' point.
#'
#' @param release_dir the release directory written by
#'   [obis_h3_export_parquet()] (holding `species/`).
#' @param aphiaid one or more seed WoRMS AphiaIDs (e.g. 2, Animalia).
#' @param res a resolution of the species table.
#' @param esn expected sample size for ES(n) (default 50).
#' @param classes optional classes to read (the partitions a class-bounded taxon
#'   needs; `NA` reads the `_none` file); NULL reads every partition.
#' @return a SQL string with columns `h3, cell_id, n, sp, shannon, simpson, es`,
#'   ordered by cell_id.
#' @concept store
#' @export
obis_h3_species_subtree_sql <- function(release_dir, aphiaid, res, esn = 50L, classes = NULL) {
  ids <- .h3t_aphiaid_ints(aphiaid)
  res <- as.integer(res)
  q   <- function(x) gsub("'", "''", x)
  d   <- normalizePath(file.path(release_dir, "species"), mustWork = TRUE)
  rd  <- glue::glue(
    "read_parquet('{q(d)}/res={res}/*/*.parquet', hive_partitioning = true, ",
    "hive_types = {{'class': 'VARCHAR'}})")
  cf  <- ""
  if (!is.null(classes)) {
    v  <- ifelse(is.na(classes), "_none", as.character(classes))  # the hive column reads decoded
    cf <- glue::glue(" AND s.class IN ({paste(.h3t_sql_quote(v), collapse = ', ')})")
  }
  lin <- paste(sprintf("list_contains(l.lineage, %d)", ids), collapse = " OR ")
  src <- glue::glue("
      SELECT s.cell_id, l.name_key AS species, SUM(s.n) AS ni
      FROM {rd} s
      JOIN read_parquet('{q(d)}/species.parquet') l USING (aphiaid)
      WHERE ({lin}){cf}
      GROUP BY 1, 2")
  glue::glue("
    SELECT lower(printf('%x', cell_id)) AS h3, cell_id, n::BIGINT AS n, sp, shannon, simpson, es
    FROM ({.h3t_indicators_sql(src, esn = as.integer(esn))}) _i
    ORDER BY cell_id")
}

# the rank key of a head in the taxon layout: WoRMS taxonRank lowercased, without a botanical
# alias in parentheses ("Phylum (Division)" -> "phylum"), so it meets the rank layers' keys
.obis_head_rank <- function(rank) {
  r <- tolower(trimws(sub("\\s*\\(.*\\)\\s*$", "", as.character(rank))))
  r[is.na(rank) | !nzchar(r)] <- NA_character_
  r
}

#' SQL for the pre-aggregated heads at one resolution
#'
#' The indicators of every head (a taxon spanning several classes, listed by
#' [obis_h3_species_heads()]) at one resolution, from `occ_h3` and the species
#' lookup: an aphiaid belongs to a head when the head's aphiaid is in its
#' `lineage`, species are counted by `name_key`, and the cells come from the
#' coarsest `occ_h3` tier at least as fine as `res` (res 4 from the res-5 tier).
#' This is the subtree [obis_h3_species_subtree_sql()] computes from the
#' exported species files, done once for the release, so a reader draws a head
#' as an ordinary taxon layer (`taxon/rank=<rank>/taxon=<name>/res=<r>/`) and
#' never reads the class files.
#'
#' @param res H3 resolution, 1 to 7.
#' @param heads the table (or a parenthesised SELECT) of heads, with columns
#'   `aphiaid`, `rank` and `taxon` (the layout keys).
#' @param lookup the table of [obis_h3_species_lookup_sql()]'s rows.
#' @param from the species-level table (default `"occ_h3"`).
#' @param esn expected sample size for ES(n) (default 50).
#' @return a SQL string with columns `rank, taxon, res, h3, cell_id, n, sp,
#'   shannon, simpson, es`.
#' @concept store
#' @export
#' @examples
#' cat(obis_h3_heads_sql(4, "heads", "species_lookup"))
obis_h3_heads_sql <- function(res, heads, lookup = "species_lookup", from = "occ_h3", esn = 50L) {
  res <- as.integer(res)
  stopifnot(length(res) == 1L, res %in% H3T_RES_IDX,
            is.character(heads), length(heads) == 1L,
            is.character(lookup), length(lookup) == 1L,
            is.character(from), length(from) == 1L)
  tier <- .obis_tier(res)
  src <- glue::glue("
      SELECT m.rank, m.taxon, CAST(h3_cell_to_parent(o.cell_id, {res}) AS BIGINT) AS cell_id,
             m.name_key AS species, SUM(o.records) AS ni
      FROM {from} o
      JOIN (SELECT h.rank, h.taxon, l.aphiaid, l.name_key
            FROM {lookup} l, unnest(l.lineage) AS u(node)
            JOIN {heads} h ON h.aphiaid = u.node) m ON o.aphiaid = m.aphiaid
      WHERE o.res = {tier}
      GROUP BY 1, 2, 3, 4")
  ind <- .h3t_indicators_sql(src, keys = c("rank", "taxon"), esn = as.integer(esn))
  glue::glue("
    SELECT rank, taxon, {res}::UTINYINT AS res, lower(printf('%x', cell_id)) AS h3, cell_id,
           n::BIGINT AS n, sp::BIGINT AS sp, shannon, simpson, es
    FROM ({ind}) _h")
}
