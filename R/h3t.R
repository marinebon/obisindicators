# build and serve OBIS biodiversity indicators as H3 hexagon tiles via the
# h3t tile factory (DuckDB SELECT -> h3j JSON). companion to the MST server
# `h3t` service (MarineSensitivity/server/h3t). see vignette("h3t").

# allowed taxonomic ranks for filtering, in descending breadth ----
H3T_RANKS <- c("phylum", "class", "order", "family", "genus", "species")

# the species-level resolution tiers stored in occ_h3 (finest = base) ----
H3T_RES_TIERS <- c(3L, 5L, 7L)
H3T_RES_BASE  <- 7L
H3T_RES_IDX   <- 1:7

#' Build the OBIS H3 DuckDB store
#'
#' Reads OBIS occurrences, bins them to H3 cells, and writes an authoritative
#' DuckDB file with two layers consumed by the `h3t` tile service:
#'
#' - `idx_h3(res, cell_id, n, sp, shannon, simpson, es)` — precomputed
#'   all-taxa indicators for resolutions 1-7 (fast default tile layers).
#' - `occ_h3(res, cell_id, aphiaid, phylum, class, "order", family, genus,
#'   species, date_year, records)` — species-level counts at resolution tiers
#'   3/5/7 for on-the-fly taxon/year-filtered queries.
#'
#' The indicator math (ES50, Shannon, Simpson, richness) is the SQL translation
#' of [calc_indicators()] (`esn` = 50 by default), validated by the package
#' tests.
#'
#' @param src occurrence source. Either a `data.frame` of occurrences, or a
#'   character vector of parquet path(s)/glob(s) readable by DuckDB
#'   (e.g. `"s3://obis-open-data/occurrence/*.parquet"`). Must expose columns
#'   `decimalLongitude`, `decimalLatitude`, `species` and (optionally)
#'   `aphiaid`, `phylum`, `class`, `order`, `family`, `genus`, `date_year`,
#'   `records`, `dropped`, `absence`. Missing taxonomic columns are filled NULL.
#' @param path_duckdb output DuckDB file path.
#' @param region_bbox optional `c(lon_min, lat_min, lon_max, lat_max)` to
#'   restrict to a region (recommended for a first/demo build).
#' @param esn expected sample size for ES(n); default 50 (matches ES50).
#' @param s3_region AWS region for `s3://` sources (default `"us-east-1"`).
#' @param s3_anonymous use anonymous S3 access for public buckets (default TRUE).
#' @param memory_limit optional DuckDB `memory_limit` (e.g. `"10GB"`). Strongly
#'   recommended when `src` is a parquet/S3 glob: a global OBIS scan will
#'   otherwise exhaust RAM and can wedge the host. Leave a few GB headroom below
#'   physical RAM.
#' @param threads optional DuckDB thread cap (e.g. `2L`) to bound CPU/RAM.
#' @param temp_dir optional directory for DuckDB to spill to disk when it
#'   exceeds `memory_limit`. Needs ample free space (a global build can spill
#'   many GB); point it at a roomy volume, not `/tmp`.
#' @param max_temp_dir_size optional cap on DuckDB disk spill (e.g. `"20GB"`).
#'   Prevents a runaway aggregation from filling the volume and crashing the
#'   host. Set to comfortably below available free disk.
#' @param overwrite overwrite an existing `path_duckdb` (default TRUE).
#'
#' @return `path_duckdb`, invisibly.
#' @concept h3t
#' @export
build_obis_h3_duckdb <- function(
  src,
  path_duckdb,
  region_bbox  = NULL,
  esn          = 50L,
  s3_region    = "us-east-1",
  s3_anonymous = TRUE,
  memory_limit     = NULL,
  threads          = NULL,
  temp_dir         = NULL,
  max_temp_dir_size = NULL,
  overwrite        = TRUE) {

  stopifnot(requireNamespace("DBI", quietly = TRUE),
            requireNamespace("duckdb", quietly = TRUE),
            requireNamespace("glue", quietly = TRUE))

  if (file.exists(path_duckdb)) {
    if (!overwrite)
      stop("path_duckdb already exists and overwrite = FALSE: ", path_duckdb)
    file.remove(path_duckdb)
  }
  dir.create(dirname(path_duckdb), showWarnings = FALSE, recursive = TRUE)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = path_duckdb, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  DBI::dbExecute(con, "INSTALL h3 FROM community; LOAD h3;")
  DBI::dbExecute(con, "INSTALL spatial; LOAD spatial;")

  # resource guards — large parquet/S3 scans must spill, not OOM the host.
  # preserve_insertion_order=false lets big aggregations release memory.
  DBI::dbExecute(con, "SET preserve_insertion_order = false;")
  if (!is.null(memory_limit))
    DBI::dbExecute(con, glue::glue("SET memory_limit = '{memory_limit}';"))
  if (!is.null(threads))
    DBI::dbExecute(con, glue::glue("SET threads = {as.integer(threads)};"))
  if (!is.null(temp_dir)) {
    dir.create(temp_dir, showWarnings = FALSE, recursive = TRUE)
    DBI::dbExecute(con, glue::glue("SET temp_directory = '{temp_dir}';"))
  }
  if (!is.null(max_temp_dir_size))
    DBI::dbExecute(con, glue::glue("SET max_temp_directory_size = '{max_temp_dir_size}';"  ))

  # source relation: a registered data.frame or a read_parquet() expression ----
  is_df <- is.data.frame(src)
  if (is_df) {
    cols            <- names(src)
    has_interpreted <- FALSE
    col_pfx         <- ""
    duckdb::duckdb_register(con, "occ_src_df", src)
    on.exit(duckdb::duckdb_unregister(con, "occ_src_df"), add = TRUE)
    from_rel     <- "occ_src_df"
    records_expr <- if ("records" %in% cols) "SUM(records)" else "COUNT(*)"
  } else {
    DBI::dbExecute(con, "INSTALL httpfs; LOAD httpfs;")
    if (any(grepl("^s3://", src))) {
      DBI::dbExecute(con, glue::glue("SET s3_region = '{s3_region}';"))
      if (s3_anonymous)
        DBI::dbExecute(con, "SET s3_access_key_id=''; SET s3_secret_access_key='';")
    }
    globs    <- paste(sprintf("'%s'", src), collapse = ", ")
    # No union_by_name: reading schema from all files at once can exhaust RAM
    # on large datasets (6 900+ OBIS parquets). Struct fields are always
    # accessed by name, so positional matching across files is safe as long as
    # the top-level column order is consistent (true for OBIS open-data).
    from_rel <- glue::glue("read_parquet([{globs}])")
    # Probe schema from ONE sample file — not the full glob.
    probe_src <- if (any(grepl("\\*", src))) {
      expanded <- Sys.glob(src)
      if (length(expanded) == 0) src[1] else expanded[1]
    } else {
      src[1]
    }
    probe_rel <- glue::glue("read_parquet('{probe_src}')")
    top_cols  <- names(DBI::dbGetQuery(
      con, glue::glue("SELECT * FROM {probe_rel} LIMIT 0")))
    # OBIS open-data parquet nests all DwC fields inside an 'interpreted'
    # struct; dropped/absence remain top-level boolean flags.
    has_interpreted <- "interpreted" %in% top_cols
    if (has_interpreted) {
      cols    <- names(DBI::dbGetQuery(
        con, glue::glue("SELECT interpreted.* FROM {probe_rel} LIMIT 0")))
      col_pfx <- "interpreted."
    } else {
      cols    <- top_cols
      col_pfx <- ""
    }
    records_expr <- if ("records" %in% tolower(cols)) "SUM(records)" else "COUNT(*)"
  }

  # DuckDB matches identifiers case-insensitively, but R name matching is not;
  # match OBIS columns (camelCase like decimalLatitude, AphiaID) accordingly.
  col_match <- function(x) {
    i <- match(tolower(x), tolower(cols))
    if (is.na(i)) NA_character_ else cols[i]
  }
  has <- function(x) !is.na(col_match(x))
  col_or_null <- function(x, type = "VARCHAR") {
    m <- col_match(x)
    if (!is.na(m)) paste0(col_pfx, sprintf('"%s"', m)) else sprintf("NULL::%s", type)
  }

  # Filter conditions — DwC fields use col_pfx; dropped/absence are always
  # top-level (whether in flat or nested OBIS struct format).
  where <- c(
    paste0(col_pfx, 'species IS NOT NULL'),
    paste0(col_pfx, 'decimalLatitude IS NOT NULL'),
    paste0(col_pfx, 'decimalLongitude IS NOT NULL'))
  if (has_interpreted) {
    where <- c(where, 'dropped IS NOT TRUE', 'absence IS NOT TRUE')
  } else {
    if (has("dropped")) where <- c(where, 'dropped IS NOT TRUE')
    if (has("absence")) where <- c(where, 'absence IS NOT TRUE')
  }
  if (!is.null(region_bbox)) {
    stopifnot(length(region_bbox) == 4)
    where <- c(where,
      glue::glue('{col_pfx}decimalLongitude BETWEEN {region_bbox[1]} AND {region_bbox[3]}'),
      glue::glue('{col_pfx}decimalLatitude  BETWEEN {region_bbox[2]} AND {region_bbox[4]}'))
  }
  where_sql <- paste(where, collapse = "\n    AND ")

  # 1. base species table at the finest resolution (res 7) ----
  message("building occ_h3 base at res ", H3T_RES_BASE, " ...")
  DBI::dbExecute(con, glue::glue("
    CREATE TABLE occ_h3_base AS
    SELECT
      CAST(h3_latlng_to_cell({col_pfx}decimalLatitude, {col_pfx}decimalLongitude, {H3T_RES_BASE}) AS BIGINT) AS cell_id,
      CAST({col_or_null('aphiaid', 'BIGINT')} AS BIGINT) AS aphiaid,
      {col_or_null('phylum')} AS phylum,
      {col_or_null('class')}  AS class,
      {col_or_null('order')}  AS \"order\",
      {col_or_null('family')} AS family,
      {col_or_null('genus')}  AS genus,
      {col_pfx}species AS species,
      CAST({col_or_null('date_year', 'SMALLINT')} AS SMALLINT) AS date_year,
      {records_expr} AS records
    FROM {from_rel}
    WHERE {where_sql}
    GROUP BY ALL;"))

  # 2. unified species-level store across resolution tiers (3/5/7) ----
  message("rolling occ_h3 tiers: ", paste(H3T_RES_TIERS, collapse = ", "))
  DBI::dbExecute(con, "
    CREATE TABLE occ_h3 (
      res UTINYINT, cell_id BIGINT, aphiaid BIGINT,
      phylum VARCHAR, class VARCHAR, \"order\" VARCHAR, family VARCHAR,
      genus VARCHAR, species VARCHAR, date_year SMALLINT, records BIGINT);")
  for (r in H3T_RES_TIERS) {
    parent <- if (r == H3T_RES_BASE) "cell_id" else
      glue::glue("CAST(h3_cell_to_parent(cell_id, {r}) AS BIGINT)")
    DBI::dbExecute(con, glue::glue("
      INSERT INTO occ_h3
      SELECT {r} AS res, {parent} AS cell_id, aphiaid,
             phylum, class, \"order\", family, genus, species, date_year,
             SUM(records) AS records
      FROM occ_h3_base
      GROUP BY ALL;"))
  }

  # 3. precomputed all-taxa indicators for res 1-7 ----
  message("computing idx_h3 indicators for res ",
          paste(range(H3T_RES_IDX), collapse = "-"), " ...")
  DBI::dbExecute(con, "
    CREATE TABLE idx_h3 (
      res UTINYINT, cell_id BIGINT, n BIGINT, sp BIGINT,
      shannon DOUBLE, simpson DOUBLE, es DOUBLE);")
  for (r in H3T_RES_IDX) {
    DBI::dbExecute(con, .h3t_idx_sql(r, esn))
  }

  DBI::dbExecute(con, "DROP TABLE occ_h3_base;")
  DBI::dbExecute(con, "CHECKPOINT;")
  message("done: ", path_duckdb)
  invisible(path_duckdb)
}

# SQL to compute all-taxa indicators at resolution `r` and INSERT into idx_h3.
# the ES(esn) per-species term is the SQL translation of calc_indicators().
.h3t_idx_sql <- function(r, esn = 50L) {
  glue::glue("
    INSERT INTO idx_h3
    WITH src AS (
      SELECT CAST(h3_cell_to_parent(cell_id, {r}) AS BIGINT) AS cell_id,
             species, SUM(records) AS ni
      FROM occ_h3 WHERE res = {H3T_RES_BASE}
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
    SELECT {r} AS res, cell_id,
      ANY_VALUE(n)                                       AS n,
      COUNT(*)                                           AS sp,
      -SUM((ni::DOUBLE / n) * ln(ni::DOUBLE / n))        AS shannon,
      SUM((ni::DOUBLE / n) * (ni::DOUBLE / n))           AS simpson,
      SUM(esi)                                           AS es
    FROM per GROUP BY cell_id;")
}

#' Build an h3t tile SQL query for an OBIS biodiversity indicator
#'
#' Generates the read-only `SELECT` (projecting exactly `cell_id, value, n`)
#' that the `h3t` service base64-decodes, validates, and executes per tile.
#' `{{res}}` is substituted server-side with the tile's H3 resolution.
#'
#' With no `taxon`/`years` filter the query reads the precomputed `idx_h3`
#' layer (fast). With a filter it computes the indicator on the fly from the
#' species-level `occ_h3` store, selecting the resolution tier that matches the
#' tile zoom.
#'
#' @param indicator one of `"es"` (ES50), `"sp"` (richness), `"shannon"`,
#'   `"n"` (# records).
#' @param taxon optional named list/vector restricting taxa, names among
#'   `phylum`, `class`, `order`, `family`, `genus`, `species`, e.g.
#'   `list(class = "Aves")` or `list(phylum = c("Mollusca", "Cnidaria"))`.
#' @param years optional `c(min, max)` year range (either may be `NA`).
#' @param esn expected sample size for ES(n); default 50.
#' @param res_max cap on the H3 resolution (1-7). Lower = coarser/bigger
#'   hexagons at a given map zoom (the "base zoom level" control); the store's
#'   finest resolution is 7. Default 7 (track zoom up to the finest).
#' @param res_placeholder the resolution placeholder; default `"{{res}}"`.
#'
#' @return a single-line-friendly SQL string.
#' @concept h3t
#' @export
obis_h3t_sql <- function(
  indicator       = c("es", "sp", "shannon", "n"),
  taxon           = NULL,
  years           = NULL,
  esn             = 50L,
  res_max         = 7L,
  res_placeholder = "{{res}}") {

  stopifnot(requireNamespace("glue", quietly = TRUE))
  indicator <- match.arg(indicator)
  r         <- res_placeholder
  rcap      <- max(1L, min(7L, as.integer(res_max)))
  eff       <- glue::glue("LEAST({r}, {rcap})")   # capped display resolution
  filt      <- .h3t_where_clause(taxon, years)
  has_filt  <- nzchar(filt)

  if (!has_filt) {
    # fast path: precomputed all-taxa indicators
    col <- switch(indicator, es = "es", sp = "sp", shannon = "shannon", n = "n")
    return(as.character(glue::glue(
      "SELECT cell_id, {col} AS value, n FROM idx_h3 WHERE res = {eff}")))
  }

  # filtered path: live indicator over the species-level store. pick the tier
  # (3/5/7) matching the capped tile res and roll cells up to it.
  tier <- glue::glue("CASE WHEN {eff} <= 3 THEN 3 WHEN {eff} <= 5 THEN 5 ELSE 7 END")
  src  <- glue::glue("
    src AS (
      SELECT CAST(h3_cell_to_parent(cell_id, {eff}) AS BIGINT) AS cell_id,
             species, SUM(records) AS ni
      FROM occ_h3
      WHERE res = {tier}
        {filt}
      GROUP BY 1, 2)")

  body <- switch(indicator,
    n = glue::glue("
      WITH {src}
      SELECT cell_id, SUM(ni) AS value, SUM(ni) AS n FROM src GROUP BY cell_id"),
    sp = glue::glue("
      WITH {src}
      SELECT cell_id, COUNT(*) AS value, SUM(ni) AS n FROM src GROUP BY cell_id"),
    shannon = glue::glue("
      WITH {src},
      tot AS (SELECT cell_id, SUM(ni) AS n FROM src GROUP BY cell_id)
      SELECT s.cell_id AS cell_id,
             -SUM((s.ni::DOUBLE / t.n) * ln(s.ni::DOUBLE / t.n)) AS value,
             ANY_VALUE(t.n) AS n
      FROM src s JOIN tot t USING (cell_id) GROUP BY s.cell_id"),
    es = glue::glue("
      WITH {src},
      tot AS (SELECT cell_id, SUM(ni) AS n FROM src GROUP BY cell_id),
      per AS (
        SELECT s.cell_id, s.ni, t.n,
          CASE
            WHEN t.n - s.ni >= {esn} THEN 1 - exp(
                   lgamma(t.n - s.ni + 1) + lgamma(t.n - {esn} + 1)
                 - lgamma(t.n - s.ni - {esn} + 1) - lgamma(t.n + 1))
            WHEN t.n >= {esn} THEN 1
            ELSE NULL END AS esi
        FROM src s JOIN tot t USING (cell_id))
      SELECT cell_id, SUM(esi) AS value, ANY_VALUE(n) AS n
      FROM per GROUP BY cell_id"))

  as.character(body)
}

#' Assemble an h3t tile (or stats) URL for an OBIS indicator
#'
#' Base64-encodes the SQL from [obis_h3t_sql()] into the `?q=` parameter.
#'
#' @param base_url tile URL template, e.g.
#'   `"https://h3tcache.marinesensitivity.org/h3t/{z}/{x}/{y}.h3t"`, or the
#'   stats endpoint `".../h3t/stats"`.
#' @param sql the SQL from [obis_h3t_sql()] (or pass `...` to build it).
#' @param release optional release tag appended as `&release=`.
#' @param db optional `&db=` registry name (default server uses `obis`).
#' @param ... passed to [obis_h3t_sql()] when `sql` is missing.
#'
#' @return the URL string with the `?q=<base64>` query embedded.
#' @concept h3t
#' @export
obis_h3t_url <- function(
  base_url = "https://h3tcache.marinesensitivity.org/h3t/{z}/{x}/{y}.h3t",
  sql      = NULL,
  release  = NULL,
  db       = NULL,
  ...) {

  if (is.null(sql)) sql <- obis_h3t_sql(...)
  q   <- gsub("\n", "", base64enc::base64encode(charToRaw(sql)))
  url <- paste0(base_url, "?q=", utils::URLencode(q, reserved = TRUE))
  if (!is.null(release)) url <- paste0(url, "&release=", release)
  if (!is.null(db))      url <- paste0(url, "&db=", db)
  url
}

# build a "AND (...)" filter fragment from taxon + years (sanitized) ----
.h3t_where_clause <- function(taxon = NULL, years = NULL) {
  parts <- character(0)

  if (!is.null(taxon)) {
    if (is.null(names(taxon)) || any(!nzchar(names(taxon))))
      stop("`taxon` must be a named list/vector, names among: ",
           paste(H3T_RANKS, collapse = ", "))
    bad <- setdiff(names(taxon), H3T_RANKS)
    if (length(bad))
      stop("unknown taxonomic rank(s): ", paste(bad, collapse = ", "))
    for (rank in names(taxon)) {
      vals <- .h3t_sql_quote(taxon[[rank]])
      col  <- sprintf('"%s"', rank)  # quote `order` (reserved word)
      parts <- c(parts, if (length(vals) == 1)
        sprintf("%s = %s", col, vals) else
        sprintf("%s IN (%s)", col, paste(vals, collapse = ", ")))
    }
  }

  if (!is.null(years)) {
    stopifnot(length(years) == 2)
    if (!is.na(years[1])) parts <- c(parts, sprintf("date_year >= %d", as.integer(years[1])))
    if (!is.na(years[2])) parts <- c(parts, sprintf("date_year <= %d", as.integer(years[2])))
  }

  if (!length(parts)) return("")
  paste0("AND ", paste(parts, collapse = "\n        AND "))
}

# single-quote SQL string literals, escaping embedded quotes ----
.h3t_sql_quote <- function(x) {
  sprintf("'%s'", gsub("'", "''", as.character(x)))
}
