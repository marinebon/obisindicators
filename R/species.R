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
  list(name = "n",        type = "BIGINT",  description = "number of occurrence records of this aphiaid in this cell"),
  list(name = "year_min", type = "SMALLINT", description = "the first year this aphiaid was recorded in this cell (NULL when no record has a year); per decade, the first year within the decade"),
  list(name = "year_max", type = "SMALLINT", description = "the last year this aphiaid was recorded in this cell (NULL when no record has a year); per decade, the last year within the decade"))

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
#' of records and `year_min`, `year_max` the first and last year recorded
#' (the Cell pane's first and last year; NULL when no record has a year). A resolution that is an `occ_h3` tier (3, 5, 7) reads that tier;
#' any other is rolled up from the next finer tier with `h3_cell_to_parent()`
#' (res 4 from the res-5 tier, as in the decade layers). Rows with a NULL
#' `aphiaid` are left out (no taxon filter can reach them).
#'
#' With `lookup`, the name of a table holding [obis_h3_species_lookup_sql()]'s
#' rows, the result has the columns of a species file plus the partition key:
#' `h3 VARCHAR, cell_id BIGINT, name_key INTEGER, aphiaid BIGINT, n BIGINT,
#' year_min SMALLINT, year_max SMALLINT, class VARCHAR` (the lookup's class, so
#' one aphiaid always lands in one partition). Without it, `cell_id, aphiaid,
#' n, year_min, year_max`. Per decade, the years are those within the decade.
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
    SELECT {key}{cell} AS cell_id, aphiaid::BIGINT AS aphiaid, SUM(records)::BIGINT AS n,
           MIN(date_year)::SMALLINT AS year_min, MAX(date_year)::SMALLINT AS year_max
    FROM {from}
    WHERE res = {tier} AND aphiaid IS NOT NULL{filt}
    GROUP BY ALL")
  if (is.null(lookup)) return(agg)
  dk <- if (decade) "s.decade, " else ""
  glue::glue("
    SELECT {dk}lower(printf('%x', s.cell_id)) AS h3, s.cell_id, l.name_key, s.aphiaid, s.n,
           s.year_min, s.year_max, l.class
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

# 0.12.0: the species_flat roll-ups and split, the split lineage file and the EOV of each species ----

# the columns of the 0.12 species_flat files (res 1, 2 and the res-3 split): those of
# species_flat/res=3.parquet without h3 (cell_id gives it)
SPECIES_FLAT_COLUMNS <- c("cell_id", "name_key", "aphiaid", "n", "year_min", "year_max")

# the lookup's eov column (0.12.0) and the lineage file's columns
SPECIES_EOV_COLUMN <- list(
  name = "eov", type = "VARCHAR",
  description = paste(
    "the EOV whose layer counts this aphiaid: the store's eov table (each EOV's IOOS seeds",
    "expanded down the WoRMS taxon tree, obis_eov_bake()) joined on taxonID = aphiaid, as the",
    "eov/ layers join occ_h3; NULL when no EOV layer counts it"))
SPECIES_LINEAGE_COLUMNS <- list(
  list(name = "aphiaid",  type = "BIGINT",   description = "WoRMS AphiaID, one row each, sorted"),
  list(name = "name_key", type = "INTEGER",  description = "the lookup's name_key"),
  list(name = "lineage",  type = "BIGINT[]", description = "the aphiaid itself, then its ancestors (the lookup's lineage)"))

#' SQL rolling a cell-sorted species table up to a coarser resolution
#'
#' One row per (cell at `res`, aphiaid) from a finer species table with the
#' columns of `species_flat/res=<r>.parquet`: `n` summed, `year_min` the least
#' and `year_max` the greatest over the finer cells (NULL only when every
#' finer row's year is NULL), `name_key` carried (one per aphiaid). This is the
#' atlas's `sumBySpecies` over a cell's children, written once in the release;
#' it equals [obis_h3_species_sql()] at `res` straight from the store, since
#' that rolls the same `occ_h3` tier up with the same sums, minima and maxima.
#'
#' @param from a table name or a table function such as
#'   `read_parquet('species_flat/res=3.parquet')`, with `cell_id`, `name_key`,
#'   `aphiaid`, `n`, `year_min` and `year_max`.
#' @param res the coarser H3 resolution (0 to 15; coarser than `from`'s).
#' @return a SQL string (a SELECT, unordered) with the columns
#'   `cell_id, name_key, aphiaid, n, year_min, year_max`.
#' @concept store
#' @export
#' @examples
#' cat(obis_h3_species_rollup_sql("read_parquet('species_flat/res=3.parquet')", 1))
obis_h3_species_rollup_sql <- function(from, res) {
  stopifnot(is.character(from), length(from) == 1L, nzchar(from),
            is.numeric(res), length(res) == 1L, res %in% 0:15)
  glue::glue("
    SELECT CAST(h3_cell_to_parent(cell_id, {as.integer(res)}) AS BIGINT) AS cell_id,
           name_key::INTEGER AS name_key, aphiaid::BIGINT AS aphiaid, SUM(n)::BIGINT AS n,
           MIN(year_min)::SMALLINT AS year_min, MAX(year_max)::SMALLINT AS year_max
    FROM {from}
    GROUP BY 1, 2, 3")
}

#' Write the species_flat roll-ups and the parent split
#'
#' From the finest cell-sorted species file `flat_dir/res=<from_res>.parquet`
#' (written by [obis_h3_export_parquet()]), writes
#'
#' - `res=<r>.parquet` for each `r` in `res` (coarser than `from_res`): one row
#'   per cell and species, [obis_h3_species_rollup_sql()], so a coarse
#'   hexagon's list is its own rows, not its children's;
#' - `res=<s>/p=<parent>.parquet` for each `s = names(split)`: the rows of
#'   `res=<s>.parquet` under one parent cell at `split[[s]]` (the parent's
#'   lowercase hex id), so a page reads a file small enough for its footer to
#'   come with the first range read.
#'
#' Every file written has the columns `cell_id, name_key, aphiaid, n,
#' year_min, year_max` (no `h3`: `cell_id` gives it, and its string statistics
#' are the largest part of a footer), sorted by `cell_id, aphiaid`, in row
#' groups of `row_group_rows` (the roll-ups) or `split_row_group_rows` (the
#' split), so the `cell_id` statistics of consecutive groups do not overlap.
#' `res=<from_res>.parquet` is read, never rewritten.
#'
#' @param con a DBI connection to DuckDB with the `h3` extension loaded.
#' @param flat_dir the release's `species_flat/` folder.
#' @param from_res the resolution of the file the others come from (default 3).
#' @param res the coarser resolutions to roll up to (default 1 and 2).
#' @param split a named integer vector, resolution = parent resolution, of the
#'   files to split (default `c("3" = 1L)`); `NULL` writes none. A split
#'   resolution must be `from_res` or one of `res`.
#' @param row_group_rows rows per row group of the roll-ups (default 10000).
#' @param split_row_group_rows rows per row group of the split files (default
#'   2048, one DuckDB vector).
#' @param compression Parquet codec (default `"zstd"`).
#' @return a data frame, one row per file written: `path` (relative to the
#'   release, `species_flat/...`), `res`, `parent` (NA for a roll-up), `rows`,
#'   `bytes`.
#' @concept store
#' @export
obis_h3_write_species_flat <- function(con, flat_dir, from_res = 3L, res = c(1L, 2L),
                                       split = c("3" = 1L), row_group_rows = 10000L,
                                       split_row_group_rows = 2048L, compression = "zstd") {
  stopifnot(
    requireNamespace("DBI", quietly = TRUE),
    is.character(flat_dir), length(flat_dir) == 1L,
    is.numeric(from_res), length(from_res) == 1L, from_res %in% H3T_RES_IDX,
    is.numeric(res), all(res %in% H3T_RES_IDX),
    is.null(split) || (is.numeric(split) && !is.null(names(split)) && all(split %in% 0:15)),
    is.numeric(row_group_rows), length(row_group_rows) == 1L, row_group_rows >= 1,
    is.numeric(split_row_group_rows), length(split_row_group_rows) == 1L, split_row_group_rows >= 1,
    grepl("^[A-Za-z0-9]+$", compression))
  from_res <- as.integer(from_res)
  res      <- sort(unique(as.integer(res)))
  if (any(res >= from_res))
    stop("res must be coarser than from_res (", from_res, "): ", paste(res[res >= from_res], collapse = ", "))
  s_res <- as.integer(names(split))
  s_par <- as.integer(split)
  if (length(split) && (anyNA(s_res) || !all(s_res %in% c(from_res, res))))
    stop("split names must be from_res or one of res: ", paste(names(split), collapse = ", "))
  if (length(split) && any(s_par >= s_res))
    stop("a split's parent resolution must be coarser than its resolution")
  q    <- function(x) gsub("'", "''", x)
  src  <- file.path(flat_dir, paste0("res=", from_res, ".parquet"))
  if (!file.exists(src)) stop("no ", src)
  cols <- paste(SPECIES_FLAT_COLUMNS, collapse = ", ")
  opts <- function(rg) glue::glue("(FORMAT PARQUET, COMPRESSION {compression}, ROW_GROUP_SIZE {as.integer(rg)})")
  out  <- data.frame(path = character(0), res = integer(0), parent = character(0),
                     rows = numeric(0), bytes = numeric(0), stringsAsFactors = FALSE)
  add  <- function(f, r, p, n) out[nrow(out) + 1L, ] <<- list(
    file.path("species_flat", substring(f, nchar(flat_dir) + 2L)), r, p, as.numeric(n), as.numeric(file.size(f)))

  # the roll-ups, each from the finest file ----
  for (r in res) {
    f <- file.path(flat_dir, paste0("res=", r, ".parquet"))
    n <- DBI::dbExecute(con, glue::glue(
      "COPY (SELECT {cols} FROM ({obis_h3_species_rollup_sql(glue::glue(\"read_parquet('{q(src)}')\"), r)}) _r
             ORDER BY cell_id, aphiaid)
       TO '{q(f)}' {opts(row_group_rows)};"))
    add(f, r, NA_character_, n)
  }

  # the split: one file per parent cell, sorted by cell ----
  tmp <- "_obis_species_flat_split"
  on.exit(DBI::dbExecute(con, glue::glue("DROP TABLE IF EXISTS {tmp};")), add = TRUE)
  for (i in seq_along(split)) {
    s <- s_res[i]; p <- s_par[i]
    f_s <- file.path(flat_dir, paste0("res=", s, ".parquet"))
    DBI::dbExecute(con, glue::glue(
      "CREATE OR REPLACE TEMP TABLE {tmp} AS
       SELECT CAST(h3_cell_to_parent(cell_id, {p}) AS BIGINT) AS _p, {cols}
       FROM read_parquet('{q(f_s)}') ORDER BY _p, cell_id, aphiaid;"))
    pp <- DBI::dbGetQuery(con, glue::glue(
      "SELECT _p::VARCHAR AS p, lower(printf('%x', _p)) AS hex, COUNT(*)::DOUBLE AS rows
       FROM {tmp} GROUP BY 1, 2 ORDER BY 2"))
    d <- file.path(flat_dir, paste0("res=", s))
    dir.create(d, showWarnings = FALSE, recursive = TRUE)
    for (j in seq_len(nrow(pp))) {
      f <- file.path(d, paste0("p=", pp$hex[j], ".parquet"))
      DBI::dbExecute(con, glue::glue(
        "COPY (SELECT {cols} FROM {tmp} WHERE _p = {pp$p[j]} ORDER BY cell_id, aphiaid)
         TO '{q(f)}' {opts(split_row_group_rows)};"))
      add(f, s, pp$hex[j], pp$rows[j])
    }
    DBI::dbExecute(con, glue::glue("DROP TABLE IF EXISTS {tmp};"))
  }
  out
}

#' SQL for the EOV of each species, as the EOV layers count it
#'
#' The EOV layers (`eov/`, `decade/eov/`, `year/eov/`, `idx_h3_eov`) count an
#' occurrence in an EOV when `occ_h3.aphiaid = eov.taxonID`, the store's `eov`
#' table holding each EOV's IOOS seeds expanded down the WoRMS taxon tree
#' ([obis_eov_bake()]). The species lookup's `eov` is that same join: the one
#' EOV whose membership holds the aphiaid, or NULL. The seeds (Agnatha,
#' Chondrichthyes, Osteichthyes; Scleractinia; the mangrove genera; Pinnipedia,
#' Cetacea, Sirenia and four species; Aves; Alismatales; Chelonioidea) are
#' disjoint subtrees of one tree, so an aphiaid is in at most one EOV;
#' `n_eov` says how many hold it, and [obis_h3_write_species_lookup()] stops
#' when any holds more than one rather than pick.
#'
#' @param eov the membership table (default `"eov"`, columns `eov`, `taxonID`).
#' @return a SQL string (a SELECT) with `aphiaid BIGINT, eov VARCHAR, n_eov`.
#' @concept eov
#' @export
#' @examples
#' cat(obis_h3_species_eov_sql())
obis_h3_species_eov_sql <- function(eov = "eov") {
  stopifnot(is.character(eov), length(eov) == 1L, nzchar(eov))
  glue::glue("
    SELECT taxonID::BIGINT AS aphiaid, MIN(eov)::VARCHAR AS eov, COUNT(DISTINCT eov)::INTEGER AS n_eov
    FROM {eov}
    GROUP BY 1")
}

#' Write the species lookup with its EOV, and the split lineage file
#'
#' Writes `dir/species.parquet` (the rows of `lookup`, ordered by aphiaid, with
#' the column `eov` of [obis_h3_species_eov_sql()] after the lookup's own
#' columns) and `dir/lineage.parquet` (`aphiaid, name_key, lineage` only, the
#' same rows), both in row groups of `row_group_rows`, so a WoRMS subtree reads
#' the lineage without the names and a list of species reads the names
#' without the lineage. Without an `eov` table (`eov = NULL`) the column is
#' left out. The rows are `lookup`'s, one per aphiaid, ordered by aphiaid (the
#' order [obis_h3_export_parquet()] writes); each file is written to a
#' temporary name and renamed, so `lookup` may read the `species.parquet` it
#' replaces.
#'
#' No IUCN Red List column is written: the store holds no Red List field (its
#' `occ_h3` and `taxon` tables carry none).
#'
#' @param con a DBI connection to DuckDB.
#' @param lookup a table name or a table function (`read_parquet('...')`) with
#'   the lookup columns of [obis_h3_species_lookup_sql()].
#' @param dir output folder (the release's `species/`).
#' @param eov the EOV membership table, or NULL (default `"eov"`).
#' @param row_group_rows rows per row group (default 10000).
#' @param compression Parquet codec (default `"zstd"`).
#' @return a data frame, one row per file: `path` (relative to the release),
#'   `rows`, `bytes`, with the attribute `eov` (the number of aphiaids per EOV,
#'   NA for none).
#' @concept store
#' @export
obis_h3_write_species_lookup <- function(con, lookup, dir, eov = "eov", row_group_rows = 10000L,
                                         compression = "zstd") {
  stopifnot(requireNamespace("DBI", quietly = TRUE),
            is.character(lookup), length(lookup) == 1L, nzchar(lookup),
            is.character(dir), length(dir) == 1L,
            is.null(eov) || (is.character(eov) && length(eov) == 1L),
            is.numeric(row_group_rows), length(row_group_rows) == 1L, row_group_rows >= 1,
            grepl("^[A-Za-z0-9]+$", compression))
  q    <- function(x) gsub("'", "''", x)
  lcol <- vapply(SPECIES_LOOKUP_COLUMNS, `[[`, "", "name")
  sel  <- paste(sprintf('l."%s"', lcol), collapse = ", ")
  tmp  <- "_obis_species_lookup_out"
  on.exit(DBI::dbExecute(con, glue::glue("DROP TABLE IF EXISTS {tmp};")), add = TRUE)
  if (is.null(eov)) {
    DBI::dbExecute(con, glue::glue(
      "CREATE OR REPLACE TEMP TABLE {tmp} AS SELECT {sel} FROM {lookup} l ORDER BY l.aphiaid;"))
  } else {
    multi <- DBI::dbGetQuery(con, glue::glue(
      "SELECT aphiaid::DOUBLE AS aphiaid FROM ({obis_h3_species_eov_sql(eov)}) e WHERE n_eov > 1 ORDER BY 1 LIMIT 5"))
    if (nrow(multi))
      stop("aphiaid(s) in more than one EOV, so one eov value would misstate the EOV layers: ",
           paste(multi$aphiaid, collapse = ", "))
    DBI::dbExecute(con, glue::glue(
      "CREATE OR REPLACE TEMP TABLE {tmp} AS
       SELECT {sel}, e.eov
       FROM {lookup} l LEFT JOIN ({obis_h3_species_eov_sql(eov)}) e ON e.aphiaid = l.aphiaid
       ORDER BY l.aphiaid;"))
  }
  # one row per aphiaid, the rows of the lookup ----
  chk  <- DBI::dbGetQuery(con, glue::glue(
    "SELECT COUNT(*)::DOUBLE AS n, COUNT(DISTINCT aphiaid)::DOUBLE AS k FROM {tmp}"))
  n_in <- DBI::dbGetQuery(con, glue::glue("SELECT COUNT(*)::DOUBLE AS n FROM {lookup}"))$n
  if (chk$n != n_in || chk$k != chk$n)
    stop("the lookup must hold one row per aphiaid (rows ", chk$n, " of ", n_in, ", distinct ", chk$k, ")")
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  opts <- glue::glue("(FORMAT PARQUET, COMPRESSION {compression}, ROW_GROUP_SIZE {as.integer(row_group_rows)})")
  ocol <- paste(sprintf('"%s"', c(lcol, if (!is.null(eov)) "eov")), collapse = ", ")
  f_sp <- file.path(dir, "species.parquet")
  f_ln <- file.path(dir, "lineage.parquet")
  DBI::dbExecute(con, glue::glue("COPY (SELECT {ocol} FROM {tmp} ORDER BY aphiaid) TO '{q(f_sp)}.tmp' {opts};"))
  DBI::dbExecute(con, glue::glue(
    "COPY (SELECT aphiaid, name_key, lineage FROM {tmp} ORDER BY aphiaid) TO '{q(f_ln)}.tmp' {opts};"))
  file.rename(paste0(f_sp, ".tmp"), f_sp)
  file.rename(paste0(f_ln, ".tmp"), f_ln)
  counts <- if (is.null(eov)) NA else DBI::dbGetQuery(con, glue::glue(
    "SELECT eov, COUNT(*)::DOUBLE AS n FROM {tmp} WHERE eov IS NOT NULL GROUP BY 1 ORDER BY 1"))
  rel <- basename(dir)
  out <- data.frame(path = file.path(rel, c("species.parquet", "lineage.parquet")),
                    rows = chk$n, bytes = as.numeric(file.size(c(f_sp, f_ln))), stringsAsFactors = FALSE)
  attr(out, "eov") <- counts
  out
}

# release.json's species_flat layer from the files under species_flat/ (path relative to the
# release, rows, bytes): the whole file per resolution and the split by parent cell
.obis_species_flat_layer <- function(files, from_res, split, row_group_rows, split_row_group_rows) {
  m      <- regmatches(files$path, regexec("^species_flat/res=([0-9]+)(/p=([0-9a-f]+))?\\.parquet$", files$path))
  ok     <- lengths(m) > 0
  files  <- files[ok, , drop = FALSE]
  files$res    <- as.integer(vapply(m[ok], `[`, "", 2L))
  files$parent <- vapply(m[ok], `[`, "", 4L)
  whole  <- files[!nzchar(files$parent), , drop = FALSE]
  parts  <- files[nzchar(files$parent), , drop = FALSE]
  res    <- sort(unique(whole$res))
  by_res <- do.call(rbind, lapply(res, function(r) data.frame(
    res = r, rows = sum(whole$rows[whole$res == r]), bytes = sum(whole$bytes[whole$res == r]),
    columns = if (r == from_res) "h3, cell_id, name_key, aphiaid, n, year_min, year_max" else
      paste(SPECIES_FLAT_COLUMNS, collapse = ", "),
    from = if (r == from_res) "occ_h3 (obis_h3_species_sql())" else
      paste0("res=", from_res, ".parquet rolled up (obis_h3_species_rollup_sql())"),
    stringsAsFactors = FALSE)))
  s_res  <- sort(unique(parts$res))
  pr     <- if (length(s_res)) stats::setNames(as.list(as.integer(split[as.character(s_res)])), s_res) else list()
  by_split <- if (length(s_res)) do.call(rbind, lapply(s_res, function(r) {
    p <- parts[parts$res == r, ]
    data.frame(res = r, parent_res = as.integer(split[[as.character(r)]]), files = nrow(p),
               rows = sum(p$rows), bytes = sum(p$bytes), max_file_bytes = max(p$bytes),
               median_file_bytes = stats::median(p$bytes))
  })) else NULL
  lay <- list(
    path           = "species_flat",
    partitions     = I(character(0)),
    template       = "species_flat/res=<res>.parquet",
    rows           = sum(files$rows),
    files          = nrow(files),
    bytes          = sum(files$bytes),
    kind           = "species",
    href_template  = "species_flat/res={res}.parquet",
    resolutions    = I(res),
    sorted_by      = I(c("cell_id", "aphiaid")),
    row_group_rows = row_group_rows,
    columns        = list(cell = "cell_id", species = "aphiaid", count = "n", name_key = "name_key",
                          year_min = "year_min", year_max = "year_max"),
    by_res         = by_res)
  if (length(s_res)) {
    lay$template_parent      <- "species_flat/res=<res>/p=<parent>.parquet"
    lay$parent_template      <- "species_flat/res={res}/p={parent}.parquet"
    lay$parent_res           <- pr
    lay$split_row_group_rows <- split_row_group_rows
    lay$split                <- by_split
  }
  lay$note <- paste(
    "the species table of species/ in one file per res for every class, sorted by cell_id,",
    "aphiaid in row groups of row_group_rows: the species of a cell are the rows with cell_id",
    "BETWEEN the first and last descendant of the cell at this res (a range read of the",
    "overlapping row groups); join species/species.parquet on aphiaid for names.",
    paste0("res=", from_res, ".parquet comes from occ_h3 and keeps h3; each coarser res is it rolled up"),
    "(n summed, year_min the least, year_max the greatest; no h3 column).",
    if (length(s_res)) paste(
      "parent_template: the same rows split by the parent cell at parent_res (no h3 column),",
      "one file per parent with records, sorted by cell_id in row groups of",
      "split_row_group_rows, so a cell reads one small file whose footer comes with the",
      "first range read; the files union to res=<res>.parquet."))
  lay
}

#' Add the 0.12 species files to a built obis-h3 release
#'
#' Amends a release written by [obis_h3_export_parquet()] 0.11 (or later) in
#' place, from its own files and the store's `eov` table, without re-running
#' the export:
#'
#' - `species/species.parquet` rewritten with the column `eov`
#'   ([obis_h3_species_eov_sql()]; same rows, same order) and
#'   `species/lineage.parquet` beside it ([obis_h3_write_species_lookup()]);
#' - `species_flat/res=<r>.parquet` for `res_flat` and the split
#'   `species_flat/res=<s>/p=<parent>.parquet` ([obis_h3_write_species_flat()]),
#'   from `species_flat/res=<from_res>.parquet`, which is not rewritten;
#' - `release.json`: `layers.species_flat` (resolutions, the split's
#'   `template_parent`, `parent_res`, `by_res`, `split`), `layers.species`
#'   (`lookup_columns` with `eov`, `lineage`, `eov`, `lookup_bytes`) and, with
#'   `manifest = TRUE`, `files.parquet` (the lookup's new size, the new files
#'   added; every other row kept).
#'
#' The collections are not written here: run [obis_h3_stac_collection()] and
#' [obis_h3_stac_stable()] after.
#'
#' @param con a DBI connection to DuckDB with the `h3` extension loaded (the
#'   store, for its `eov` table).
#' @param release_dir the release directory.
#' @param from_res the resolution of the existing flat file (default 3).
#' @param res_flat the coarser resolutions to roll up to (default 1 and 2).
#' @param split resolution = parent resolution of the split (default `c("3" = 1L)`).
#' @param eov the EOV membership table, or NULL for no `eov` column.
#' @param row_group_rows rows per row group of the roll-ups, the lookup and the
#'   lineage file (default 10000).
#' @param split_row_group_rows rows per row group of the split (default 2048).
#' @param manifest also update `files.parquet` (default TRUE).
#' @param compression Parquet codec (default `"zstd"`).
#' @return invisibly, a data frame of the files written (`path`, `rows`,
#'   `bytes`), with the attribute `eov` (aphiaids per EOV).
#' @concept store
#' @export
obis_h3_amend_species <- function(con, release_dir, from_res = 3L, res_flat = c(1L, 2L),
                                  split = c("3" = 1L), eov = "eov", row_group_rows = 10000L,
                                  split_row_group_rows = 2048L, manifest = TRUE, compression = "zstd") {
  stopifnot(requireNamespace("DBI", quietly = TRUE), requireNamespace("jsonlite", quietly = TRUE),
            is.character(release_dir), length(release_dir) == 1L, dir.exists(release_dir),
            is.logical(manifest), length(manifest) == 1L, !is.na(manifest))
  rel   <- normalizePath(release_dir)
  f_js  <- file.path(rel, "release.json")
  f_man <- file.path(rel, "files.parquet")
  f_lk  <- file.path(rel, "species", "species.parquet")
  stopifnot("release_dir has no release.json" = file.exists(f_js),
            "release_dir has no species/species.parquet" = file.exists(f_lk),
            "release_dir has no files.parquet (manifest = FALSE skips it)" = !manifest || file.exists(f_man))
  if (!is.null(eov) && !.obis_has_table(con, eov)) stop("no table ", eov, " (eov = NULL leaves the column out)")
  q <- function(x) gsub("'", "''", x)

  lk <- obis_h3_write_species_lookup(con, glue::glue("read_parquet('{q(f_lk)}')"), file.path(rel, "species"),
                                     eov = eov, row_group_rows = row_group_rows, compression = compression)
  sf <- obis_h3_write_species_flat(con, file.path(rel, "species_flat"), from_res = from_res, res = res_flat,
                                   split = split, row_group_rows = row_group_rows,
                                   split_row_group_rows = split_row_group_rows, compression = compression)

  # every species_flat file on disk, the existing one included ----
  fl <- sort(list.files(file.path(rel, "species_flat"), pattern = "\\.parquet$", recursive = TRUE))
  fl <- file.path("species_flat", fl)
  nr <- vapply(file.path(rel, fl), function(f) as.numeric(DBI::dbGetQuery(con, sprintf(
    "SELECT num_rows FROM parquet_file_metadata('%s') LIMIT 1", q(f)))$num_rows), numeric(1))
  flat <- data.frame(path = fl, rows = unname(nr), bytes = as.numeric(file.size(file.path(rel, fl))),
                     stringsAsFactors = FALSE)

  # release.json ----
  js <- jsonlite::read_json(f_js)
  rg <- as.integer(row_group_rows)
  js$layers$species_flat <- .obis_species_flat_layer(flat, as.integer(from_res), split, rg,
                                                     as.integer(split_row_group_rows))
  sp <- js$layers$species
  if (!is.null(sp)) {
    lc <- Filter(function(x) !identical(x$name, "eov"), sp$lookup_columns)
    sp$lookup_columns <- c(lc, if (!is.null(eov)) list(SPECIES_EOV_COLUMN))
    sp$lookup_bytes   <- lk$bytes[1]
    sp$lineage        <- .obis_species_lineage_meta(lk$bytes[2], lk$rows[2], rg)
    sp$eov            <- .obis_species_eov_meta(attr(lk, "eov"))
    js$layers$species <- sp
  }

  # files.parquet ----
  out <- c(f_js, file.path(rel, lk$path), file.path(rel, sf$path))
  if (manifest) {
    old  <- DBI::dbGetQuery(con, sprintf("SELECT * FROM read_parquet('%s')", q(f_man)))
    new  <- rbind(
      data.frame(layer = "species_lookup", path = "species/species.parquet", rows = lk$rows[1], bytes = lk$bytes[1]),
      data.frame(layer = "species_lineage", path = "species/lineage.parquet", rows = lk$rows[2], bytes = lk$bytes[2]),
      data.frame(layer = "species_flat", path = flat$path, rows = flat$rows, bytes = flat$bytes))
    new$url_path <- gsub("%", "%25", new$path, fixed = TRUE)
    new$parent   <- ifelse(grepl("/p=[0-9a-f]+\\.parquet$", new$path),
                           sub(".*/p=([0-9a-f]+)\\.parquet$", "\\1", new$path), NA_character_)
    keep <- old[!old$path %in% new$path, , drop = FALSE]
    all  <- rbind(keep[, names(new)], new[, names(new)])
    duckdb::duckdb_register(con, "amend_species_files", all)
    on.exit(duckdb::duckdb_unregister(con, "amend_species_files"), add = TRUE)
    f_tmp <- paste0(f_man, ".tmp")
    DBI::dbExecute(con, sprintf(
      "COPY (SELECT layer, path, url_path, rows::BIGINT AS rows, bytes::BIGINT AS bytes,
                    parent::VARCHAR AS parent FROM amend_species_files ORDER BY path)
       TO '%s' (FORMAT PARQUET, COMPRESSION %s);", q(f_tmp), compression))
    file.rename(f_tmp, f_man)
    if (!is.null(js$files)) js$files$n_files <- nrow(all) + 1L
    out <- c(out, f_man)
  }
  jsonlite::write_json(js, f_js, auto_unbox = TRUE, pretty = TRUE, digits = NA, null = "null",
                       dataframe = "rows")
  res <- rbind(lk[, c("path", "rows", "bytes")], sf[, c("path", "rows", "bytes")])
  attr(res, "eov") <- attr(lk, "eov")
  invisible(res)
}

# release.json's species.lineage and species.eov entries
.obis_species_lineage_meta <- function(bytes, rows, row_group_rows) list(
  href = "species/lineage.parquet", key = "aphiaid", lineage_column = "lineage",
  columns = SPECIES_LINEAGE_COLUMNS, sorted_by = I("aphiaid"), row_group_rows = row_group_rows,
  rows = rows, bytes = bytes,
  note = paste(
    "the lookup's aphiaid, name_key and lineage only (the same rows, sorted by aphiaid), so a",
    "WoRMS subtree (list_contains(lineage, <aphiaid>)) reads it without the names"))
.obis_species_eov_meta <- function(counts) {
  if (!is.data.frame(counts)) return(NULL)
  list(column = "eov", n = stats::setNames(as.list(counts$n), counts$eov),
       rule = SPECIES_EOV_COLUMN$description,
       redlist = paste(
         "no Red List column: the store's occ_h3 and taxon tables carry no IUCN Red List field"))
}
