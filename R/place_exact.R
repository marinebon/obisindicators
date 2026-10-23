# exact point-in-polygon OBIS indicators per place (no H3): every occurrence
# location is tested against the true polygon, then the indicators are the same
# SQL as the store's precomputed layers (.h3t_indicators_sql(), the translation
# of calc_indicators()), with place_id standing in for cell_id as in
# obis_place_indicators(). companion to the area-weighted H3 version in place.R.

# default decades, as the export's decade layers ----
PLACE_EXACT_DECADES <- seq(1960L, 2020L, by = 10L)
# most quadrant-subdivision rounds of the place polygons before giving up
PLACE_EXACT_MAX_ROUNDS <- 24L

#' Exact point-in-polygon indicators per place
#'
#' Computes the biodiversity indicators of each place of a polygon collection
#' (EEZs, offshore regions, sanctuaries, ...) from the OBIS occurrences that
#' fall **inside the polygon**, tested point by point with DuckDB's spatial
#' extension, with no H3 approximation. This complements
#' [obis_place_indicators()], which pools area-weighted H3 cells.
#'
#' The method:
#'
#' 1. **Occurrence filters** as [build_obis_h3_duckdb()]: `species`,
#'    `decimalLatitude` and `decimalLongitude` not null; `dropped` and `absence`
#'    not true. Records are grouped by (longitude, latitude, `aphiaid`,
#'    `species`, year), `records` being the row count (or the sum of a
#'    `records` column when the source has one).
#' 2. **Place pieces**: each polygon is dumped into its parts (so a place split
#'    at +/-180 becomes local parts with local bounding boxes), and every part
#'    with more than `max_vertices` vertices is cut into the four quadrants of its
#'    own bounding box (`ST_Intersection`, empties dropped, parts dumped again),
#'    round after round until every piece is small. The spatial join then tests
#'    points against small pieces instead of rings with hundreds of thousands of
#'    vertices. Each round is a table (so DuckDB can spill) and copies a geometry
#'    at most four times; at most 24 rounds, else an error.
#' 3. **Join**: each distinct location is matched to the pieces with
#'    `ST_Intersects` (DuckDB's R-tree spatial join) and then to its `place_id`.
#'    A location on the shared boundary of two places matches both; these are
#'    counted in `diagnostics$overlaps` and warned about.
#' 4. **Indicators** per place, by EOV (`"all"` plus each EOV in `eov`) and by
#'    decade (all years, then each of `decades`) or by year, with the shared
#'    indicator SQL (the ES(`esn`) term of the parity contract is untouched).
#'
#' Polygons must be valid (no self-intersections); a point exactly on a
#' polygon edge counts as inside.
#'
#' @param occ the occurrences: a `data.frame` with `decimalLongitude`,
#'   `decimalLatitude`, `species` and optionally `date_year`, `records` and
#'   `aphiaid` (needed for `eov`), or parquet path(s)/glob(s) of OBIS open data
#'   (`s3://` URLs too), either the nested layout (DwC fields in an
#'   `interpreted` struct) or flat. The schema is probed from one file.
#' @param places the places: an `sf` object, or the path(s) of GeoParquet
#'   file(s), with a `place_id` column and polygon geometry (WKB `geometry`),
#'   e.g. a gazetteer `places.parquet`. An optional `area_km2` column is used
#'   for `density`; without it the geodesic area is computed from the geometry
#'   (`ST_Area_Spheroid`). `place_id` must be unique.
#' @param eov EOV membership for the `eov` rows: `NULL` (none), a data frame
#'   with columns `eov` and `taxonID` (matched to `aphiaid`), or a `DBI`
#'   connection to a store with an `eov` table (see [obis_eov_bake()]).
#' @param decades decades (first year) to compute besides all years: `TRUE`
#'   (default) for 1960-2020 as in the export, `FALSE` or `NULL` for none, or an
#'   integer vector.
#' @param years per-year rows: `TRUE` (default) every year with records,
#'   `FALSE` or `NULL` none, or an integer vector of years.
#' @param esn expected sample size for ES(n); default 50.
#' @param max_vertices the most vertices a polygon piece may have before it is
#'   cut into quadrants (default 256, at least 8). It only affects speed and
#'   memory, not results.
#' @param con optional DuckDB connection to use (the `spatial` extension is
#'   loaded into it); default a private in-memory one. Temporary tables are
#'   dropped on exit.
#' @param memory_limit,threads,temp_dir,max_temp_dir_size DuckDB resource
#'   guards, as in [build_obis_h3_duckdb()]. Pass them for a global parquet
#'   scan, which otherwise can exhaust RAM.
#' @param s3_region,s3_anonymous for `s3://` sources, as in
#'   [build_obis_h3_duckdb()].
#' @param verbose message progress.
#' @param grid_deg deprecated and ignored (the polygons used to be clipped to a
#'   grid); a message is shown when it is given.
#'
#' @return a list with
#'   - `indicators`: one row per place x `eov` (`"all"` or the EOV) x `decade`
#'     (NA = all years) with records: `place_id`, `eov`, `decade`, `n` (records),
#'     `sp` (species), `shannon`, `simpson` (sum of p^2), `es` (ES(`esn`), NA
#'     where `n < esn`), `hill_1` (`exp(shannon)`), `hill_2` (`1 / simpson`),
#'     `bp` (Berger-Parker, `max(ni) / n`, the `maxp` of [calc_indicators()])
#'     and `density` (`n / area_km2`, records per km2).
#'   - `years`: the same per place x `eov` x `year`.
#'   - `diagnostics`: `records_in` (records summed over the places, all taxa and
#'     years), `records_out` (filtered records outside every place),
#'     `records_total` (filtered records), `records_in_unique` (`records_total -
#'     records_out`, `records_in` without double counting overlaps), `overlaps`
#'     (a list: `n` locations that match more than one place, their `place_ids`
#'     and `records`), `n_places`, `n_places_with_records`, `n_locations`
#'     (distinct locations), `n_pieces`, `max_vertices`, `max_piece_vertices` (the largest piece) and
#'     `subdivision_rounds`.
#'
#'   Without overlapping places, `records_in + records_out == records_total`.
#' @concept analyze
#' @export
#' @examples
#' \dontrun{
#' res <- obis_place_indicators_exact(
#'   "/data/obis/occurrence/*.parquet", "~/data/places/mr_eez/places.parquet",
#'   eov = obis_store_connect("~/data/obis/obis_h3.duckdb"),
#'   memory_limit = "16GB", threads = 6, temp_dir = "/data/tmp")
#' obis_place_exact_write(res, "~/data/obis-h3/v20261020", "mr_eez")
#' }
obis_place_indicators_exact <- function(
  occ,
  places,
  eov               = NULL,
  decades           = TRUE,
  years             = TRUE,
  esn               = 50L,
  max_vertices      = 256L,
  con               = NULL,
  memory_limit      = NULL,
  threads           = NULL,
  temp_dir          = NULL,
  max_temp_dir_size = NULL,
  s3_region         = "us-east-1",
  s3_anonymous      = TRUE,
  verbose           = FALSE,
  grid_deg          = NULL) {

  stopifnot(requireNamespace("DBI", quietly = TRUE),
            requireNamespace("duckdb", quietly = TRUE),
            is.numeric(esn), length(esn) == 1L, esn >= 1,
            is.numeric(max_vertices), length(max_vertices) == 1L, is.finite(max_vertices),
            max_vertices >= 8)
  if (!is.null(grid_deg))
    message("`grid_deg` is deprecated and ignored: polygons are now subdivided to at most ",
            "`max_vertices` vertices per piece (quadrant subdivision, see ?obis_place_indicators_exact)")
  esn <- as.integer(esn)
  say <- function(...) if (verbose) message(...)

  decades <- .pe_decades(decades)
  yrs     <- .pe_years(years)

  if (is.null(con)) {
    con <- DBI::dbConnect(duckdb::duckdb())
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  }
  .pe_setup(con, memory_limit, threads, temp_dir, max_temp_dir_size)
  .pe_load_ext(con, "spatial")

  # temp objects, dropped on exit ----
  id  <- as.integer(stats::runif(1, 1e6, 1e7))
  nm  <- function(x) paste0("pe", id, "_", x)
  tbl <- list(pl = nm("places"), pcs = nm("pieces"), occ = nm("occ"), loc = nm("loc"),
              lp = nm("loc_place"), po = nm("place_occ"), ov = nm("overlap"), eov = nm("eov"),
              cur = nm("cur"), nxt = nm("next"))
  vws <- character(0)
  on.exit({
    for (v in vws) try(duckdb::duckdb_unregister(con, v), silent = TRUE)
    for (t in unlist(tbl)) try(DBI::dbExecute(con, paste0("DROP TABLE IF EXISTS ", t)), silent = TRUE)
  }, add = TRUE, after = FALSE)  # before the disconnect above

  # places: (place_id, area_km2, geom) ----
  pl <- .pe_places(con, places, nm("places_src"))
  vws <- c(vws, pl$view)
  DBI::dbExecute(con, glue::glue("
    CREATE TEMP TABLE {tbl$pl} AS
    SELECT place_id, geom,
           CASE WHEN area_km2 IS NOT NULL THEN area_km2
                ELSE ST_Area_Spheroid(ST_FlipCoordinates(geom)) / 1e6 END AS area_km2
    FROM ({pl$sql}) WHERE geom IS NOT NULL"))
  np <- DBI::dbGetQuery(con, glue::glue(
    "SELECT COUNT(*)::INTEGER AS n, COUNT(DISTINCT place_id)::INTEGER AS u,
            COUNT(place_id)::INTEGER AS nn FROM {tbl$pl}"))
  if (np$n == 0L) stop("`places` has no geometry")
  if (np$nn != np$n) stop("`places` has NULL place_id")
  if (np$u != np$n) stop("`places$place_id` must be unique")
  say("places: ", np$n)

  # place pieces: each polygon part cut into quadrants until it has <= max_vertices vertices ----
  # (each round writes a table, so DuckDB can spill; a geometry is copied at most 4 times per round)
  mv <- as.integer(max_vertices)
  DBI::dbExecute(con, glue::glue("
    CREATE TEMP TABLE {tbl$cur} AS
    SELECT place_id, g AS geom, ST_NPoints(g)::INTEGER AS npts
    FROM (SELECT place_id, d.geom AS g, ST_GeometryType(d.geom) AS gt
          FROM (SELECT place_id, unnest(ST_Dump(geom)) AS d FROM {tbl$pl}))
    WHERE gt = 'POLYGON' AND NOT ST_IsEmpty(g)"))
  DBI::dbExecute(con, glue::glue("CREATE TEMP TABLE {tbl$pcs} (place_id VARCHAR, geom GEOMETRY)"))
  rounds <- 0L
  repeat {
    DBI::dbExecute(con, glue::glue(
      "INSERT INTO {tbl$pcs} SELECT place_id, geom FROM {tbl$cur} WHERE npts <= {mv}"))
    n_big <- DBI::dbGetQuery(con, glue::glue(
      "SELECT COUNT(*)::DOUBLE AS n FROM {tbl$cur} WHERE npts > {mv}"))$n
    if (n_big == 0) break
    if (rounds >= PLACE_EXACT_MAX_ROUNDS)
      stop(n_big, " polygon piece(s) still have more than ", mv, " vertices after ",
           PLACE_EXACT_MAX_ROUNDS, " subdivision rounds; raise `max_vertices`", call. = FALSE)
    rounds <- rounds + 1L
    say("subdivision round ", rounds, ": ", format(n_big, big.mark = ",", scientific = FALSE),
        " piece(s) over ", mv, " vertices")
    DBI::dbExecute(con, glue::glue("
      CREATE TEMP TABLE {tbl$nxt} AS
      WITH big AS (
        SELECT place_id, geom,
               ST_XMin(geom) AS x0, ST_YMin(geom) AS y0,
               (ST_XMin(geom) + ST_XMax(geom)) / 2 AS xm, (ST_YMin(geom) + ST_YMax(geom)) / 2 AS ym,
               ST_XMax(geom) AS x1, ST_YMax(geom) AS y1
        FROM {tbl$cur} WHERE npts > {mv}),
      quad AS (
        SELECT place_id, geom,
               ST_MakeEnvelope(CASE i WHEN 0 THEN x0 ELSE xm END, CASE j WHEN 0 THEN y0 ELSE ym END,
                               CASE i WHEN 0 THEN xm ELSE x1 END, CASE j WHEN 0 THEN ym ELSE y1 END) AS env
        FROM big, (VALUES (0, 0), (0, 1), (1, 0), (1, 1)) q(i, j)),
      cut AS (
        SELECT place_id, ST_CollectionExtract(ST_Intersection(geom, env), 3) AS g
        FROM quad WHERE ST_Intersects(geom, env)),
      prt AS (
        SELECT place_id, unnest(ST_Dump(g)) AS d FROM cut WHERE NOT ST_IsEmpty(g))
      SELECT place_id, d.geom AS geom, ST_NPoints(d.geom)::INTEGER AS npts
      FROM prt WHERE ST_GeometryType(d.geom) = 'POLYGON' AND NOT ST_IsEmpty(d.geom)"))
    DBI::dbExecute(con, glue::glue("DROP TABLE {tbl$cur}"))
    DBI::dbExecute(con, glue::glue("ALTER TABLE {tbl$nxt} RENAME TO {tbl$cur}"))
  }
  DBI::dbExecute(con, glue::glue("DROP TABLE IF EXISTS {tbl$cur}"))
  pc <- DBI::dbGetQuery(con, glue::glue(
    "SELECT COUNT(*)::DOUBLE AS n, COALESCE(MAX(ST_NPoints(geom)), 0)::DOUBLE AS mx FROM {tbl$pcs}"))
  n_pieces <- pc$n
  say("place pieces: ", format(n_pieces, big.mark = ",", scientific = FALSE), " of at most ", mv,
      " vertices after ", rounds, " round(s)")

  # occurrences, filtered and grouped as build_obis_h3_duckdb() ----
  src <- .pe_occ_source(con, occ, nm("occ_src"), s3_region, s3_anonymous)
  vws <- c(vws, src$view)
  DBI::dbExecute(con, glue::glue("
    CREATE TEMP TABLE {tbl$occ} AS
    SELECT {src$lon}::DOUBLE AS lon, {src$lat}::DOUBLE AS lat,
           CAST({src$aphiaid} AS BIGINT) AS aphiaid,
           {src$species} AS species,
           CAST({src$year} AS SMALLINT) AS date_year,
           CAST({src$records} AS BIGINT) AS records
    FROM {src$from}
    WHERE {src$where}
    GROUP BY ALL"))
  DBI::dbExecute(con, glue::glue("
    CREATE TEMP TABLE {tbl$loc} AS
    SELECT lon, lat, ST_Point(lon, lat) AS pt FROM (SELECT DISTINCT lon, lat FROM {tbl$occ})"))
  n_loc <- DBI::dbGetQuery(con, glue::glue("SELECT COUNT(*)::DOUBLE AS n FROM {tbl$loc}"))$n
  say("distinct locations: ", format(n_loc, big.mark = ",", scientific = FALSE))

  # spatial join: locations -> pieces -> place_id ----
  DBI::dbExecute(con, glue::glue("
    CREATE TEMP TABLE {tbl$lp} AS
    SELECT DISTINCT l.lon, l.lat, p.place_id
    FROM {tbl$loc} l JOIN {tbl$pcs} p ON ST_Intersects(p.geom, l.pt)"))
  DBI::dbExecute(con, glue::glue("
    CREATE TEMP TABLE {tbl$po} AS
    SELECT lp.place_id, o.aphiaid, o.species, o.date_year, SUM(o.records) AS records
    FROM {tbl$occ} o JOIN {tbl$lp} lp USING (lon, lat)
    GROUP BY ALL"))

  # diagnostics: totals and overlaps ----
  DBI::dbExecute(con, glue::glue("
    CREATE TEMP TABLE {tbl$ov} AS
    SELECT lon, lat FROM {tbl$lp} GROUP BY lon, lat HAVING COUNT(*) > 1"))
  dg <- DBI::dbGetQuery(con, glue::glue("
    SELECT (SELECT COALESCE(SUM(records), 0) FROM {tbl$po})::DOUBLE AS records_in,
           (SELECT COALESCE(SUM(records), 0) FROM {tbl$occ})::DOUBLE AS records_total,
           (SELECT COALESCE(SUM(o.records), 0)
              FROM {tbl$occ} o ANTI JOIN (SELECT DISTINCT lon, lat FROM {tbl$lp}) u
                   USING (lon, lat))::DOUBLE AS records_out,
           (SELECT COUNT(*) FROM {tbl$ov})::DOUBLE AS ov_n,
           (SELECT COALESCE(SUM(o.records), 0)
              FROM {tbl$occ} o SEMI JOIN {tbl$ov} USING (lon, lat))::DOUBLE AS ov_records,
           (SELECT COUNT(DISTINCT place_id) FROM {tbl$po})::DOUBLE AS n_with"))
  ov_ids <- DBI::dbGetQuery(con, glue::glue("
    SELECT DISTINCT place_id FROM {tbl$lp} SEMI JOIN {tbl$ov} USING (lon, lat)
    ORDER BY place_id"))$place_id
  diagnostics <- list(
    records_in            = dg$records_in,
    records_out           = dg$records_out,
    records_total         = dg$records_total,
    records_in_unique     = dg$records_total - dg$records_out,
    overlaps              = list(n = dg$ov_n, place_ids = ov_ids, records = dg$ov_records),
    n_places              = np$n,
    n_places_with_records = dg$n_with,
    n_locations           = n_loc,
    n_pieces              = n_pieces,
    max_vertices          = mv,
    max_piece_vertices    = pc$mx,
    subdivision_rounds    = rounds)
  if (dg$ov_n > 0)
    warning(format(dg$ov_n, big.mark = ",", scientific = FALSE), " location(s) match more than one place (",
            dg$ov_records, " records counted in each): ",
            paste(utils::head(ov_ids, 10), collapse = ", "),
            if (length(ov_ids) > 10) ", ..." else "",
            ". records_in + records_out exceeds records_total; use records_in_unique.",
            call. = FALSE)
  say("records: in ", dg$records_in, ", out ", dg$records_out, ", total ", dg$records_total)

  # EOV membership ----
  eovs <- character(0)
  if (!is.null(eov)) {
    if (!src$has_aphiaid) stop("`eov` needs an `aphiaid` column in `occ`")
    m <- .pe_eov_membership(eov)
    if ("all" %in% m$eov) stop("an EOV cannot be named 'all'")
    vw <- nm("eov_src")
    duckdb::duckdb_register(con, vw, m)
    vws <- c(vws, vw)
    DBI::dbExecute(con, glue::glue("
      CREATE TEMP TABLE {tbl$eov} AS
      SELECT DISTINCT eov::VARCHAR AS eov, taxonID::BIGINT AS taxonID FROM {vw}"))
    eovs <- sort(unique(m$eov))
  }

  # indicators: one query per (all | eov) x (all years | decade | year) ----
  dec_expr <- function() "CAST(floor(p.date_year / 10) * 10 AS INTEGER)"
  part <- function(is_eov, tdim) {
    key_expr <- if (is_eov) "e.eov" else "'all'"
    join_eov <- if (is_eov) glue::glue("JOIN {tbl$eov} e ON p.aphiaid = e.taxonID") else ""
    tkey     <- switch(tdim, none = character(0), decade = "decade", year = "year")
    t_in     <- switch(tdim, none = "", decade = glue::glue("{dec_expr()} AS decade, "),
                       year = "CAST(p.date_year AS INTEGER) AS year, ")
    where    <- switch(tdim,
      none   = "TRUE",
      decade = glue::glue("p.date_year IS NOT NULL AND {dec_expr()} IN ({paste(decades, collapse = ', ')})"),
      year   = if (is.null(yrs)) "p.date_year IS NOT NULL" else
        glue::glue("p.date_year IN ({paste(yrs, collapse = ', ')})"))
    keys     <- c("eov", tkey)
    grp      <- paste(seq_len(length(keys) + 2L), collapse = ", ")  # cell_id, keys, species
    kj       <- paste(keys, collapse = ", ")
    ind <- .h3t_indicators_sql(
      glue::glue("SELECT cell_id, {kj}, species, ni FROM lay"),
      keys = keys, select = glue::glue("cell_id AS place_id, {kj}"), esn = esn)
    t_out <- switch(tdim, none = "NULL::INTEGER AS decade", decade = "i.decade",
                    year = "i.year")
    glue::glue("
      WITH lay AS (
        SELECT p.place_id AS cell_id, {key_expr} AS eov, {t_in}
               p.species, SUM(p.records) AS ni
        FROM {tbl$po} p {join_eov}
        WHERE {where}
        GROUP BY {grp}),
      ind AS ({ind}),
      bp AS (
        SELECT cell_id AS place_id, {kj}, MAX(ni)::DOUBLE / SUM(ni) AS bp
        FROM lay GROUP BY ALL)
      SELECT i.place_id, i.eov, {t_out},
             i.n::DOUBLE AS n, i.sp::INTEGER AS sp, i.shannon::DOUBLE AS shannon,
             i.simpson::DOUBLE AS simpson, i.es::DOUBLE AS es,
             exp(i.shannon) AS hill_1, 1 / i.simpson AS hill_2, b.bp AS bp,
             i.n::DOUBLE / a.area_km2 AS density
      FROM ind i JOIN bp b USING (place_id, {kj})
      LEFT JOIN {tbl$pl} a ON a.place_id = i.place_id")
  }
  run <- function(parts, tcol) {
    if (!length(parts))
      return(NULL)
    sql <- paste0("SELECT * FROM (\n",
                  paste0("SELECT * FROM (", parts, ")", collapse = "\nUNION ALL BY NAME\n"),
                  "\n) ORDER BY place_id, (eov <> 'all'), eov, ", tcol, " NULLS FIRST")
    out <- DBI::dbGetQuery(con, sql)
    rownames(out) <- NULL
    out
  }
  empty <- function(tcol) {
    d <- data.frame(place_id = character(0), eov = character(0), t = integer(0),
                    n = numeric(0), sp = integer(0), shannon = numeric(0),
                    simpson = numeric(0), es = numeric(0), hill_1 = numeric(0),
                    hill_2 = numeric(0), bp = numeric(0), density = numeric(0),
                    stringsAsFactors = FALSE)
    names(d)[3] <- tcol
    d
  }
  sets <- c(list(FALSE), if (length(eovs)) list(TRUE))
  say("indicators: all years", if (length(decades)) " and decades", " ...")
  p_ind <- unlist(lapply(sets, function(e)
    c(list(part(e, "none")), if (length(decades)) list(part(e, "decade")))), recursive = FALSE)
  indicators <- run(p_ind, "decade")
  say("indicators: years ...")
  p_yr <- if (is.null(yrs) || length(yrs)) lapply(sets, function(e) part(e, "year"))
  years_df <- run(p_yr, "year")
  if (is.null(years_df)) years_df <- empty("year")

  list(indicators = indicators, years = years_df, diagnostics = diagnostics)
}

#' Write the exact place indicators as Parquet
#'
#' Writes the result of [obis_place_indicators_exact()] as the public derived
#' tables of the `obis-h3` release: values only, no geometry.
#'
#' ```
#' <dir>/place_exact/coll=<coll>/indicators.parquet   place_id, eov, decade, n, sp, shannon,
#'                                                    simpson, es, hill_1, hill_2, bp, density
#' <dir>/place_exact/coll=<coll>/years.parquet        place_id, eov, year, n, sp, shannon,
#'                                                    simpson, es, hill_1, hill_2, bp, density
#' <dir>/place_exact/coll=<coll>/meta.json            coll, places, rows, records_in/out/total,
#'                                                    overlaps, created, obisindicators_version
#' ```
#'
#' The Parquet files are ZSTD compressed (DuckDB `COPY`), ordered by place.
#'
#' @param result the list returned by [obis_place_indicators_exact()].
#' @param dir output directory (a release directory); files go under
#'   `dir/place_exact/coll=<coll>/`.
#' @param coll the collection slug (letters, digits, `.`, `_`, `-`).
#'
#' @return invisibly, the paths of the three files written.
#' @concept analyze
#' @export
obis_place_exact_write <- function(result, dir, coll) {
  stopifnot(requireNamespace("DBI", quietly = TRUE),
            requireNamespace("duckdb", quietly = TRUE),
            requireNamespace("jsonlite", quietly = TRUE),
            is.list(result), all(c("indicators", "years") %in% names(result)),
            is.character(dir), length(dir) == 1L, nzchar(dir),
            is.character(coll), length(coll) == 1L, grepl("^[A-Za-z0-9._-]+$", coll))
  d <- file.path(path.expand(dir), "place_exact", paste0("coll=", coll))
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  d <- normalizePath(d)
  q <- function(x) gsub("'", "''", x)

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  vals <- "n::DOUBLE AS n, sp::INTEGER AS sp, shannon::DOUBLE AS shannon,
           simpson::DOUBLE AS simpson, es::DOUBLE AS es, hill_1::DOUBLE AS hill_1,
           hill_2::DOUBLE AS hill_2, bp::DOUBLE AS bp, density::DOUBLE AS density"
  one <- function(df, tcol, file) {
    vw <- paste0("pe_write_", tcol)
    duckdb::duckdb_register(con, vw, df)
    on.exit(duckdb::duckdb_unregister(con, vw), add = TRUE)
    DBI::dbExecute(con, glue::glue("
      COPY (
        SELECT place_id::VARCHAR AS place_id, eov::VARCHAR AS eov, {tcol}::INTEGER AS {tcol}, {vals}
        FROM {vw} ORDER BY place_id, (eov <> 'all'), eov, {tcol} NULLS FIRST
      ) TO '{q(file)}' (FORMAT PARQUET, COMPRESSION ZSTD);"))
    file
  }
  f_ind <- one(result$indicators, "decade", file.path(d, "indicators.parquet"))
  f_yr  <- one(result$years, "year", file.path(d, "years.parquet"))

  dg <- result$diagnostics
  meta <- list(
    coll                   = coll,
    n_places               = length(unique(c(result$indicators$place_id, result$years$place_id))),
    rows                   = list(indicators = nrow(result$indicators), years = nrow(result$years)),
    records_in             = dg$records_in,
    records_out            = dg$records_out,
    records_total          = dg$records_total,
    overlaps               = dg$overlaps$n,
    created                = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    obisindicators_version = .obisindicators_version())
  f_meta <- file.path(d, "meta.json")
  jsonlite::write_json(meta, f_meta, auto_unbox = TRUE, pretty = TRUE, digits = NA, na = "null")
  invisible(c(f_ind, f_yr, f_meta))
}

#' Add an exact place collection to an existing `obis-h3` release
#'
#' [obis_place_exact_write()] puts `place_exact/coll=<coll>/` into a release
#' directory; this registers it the way [obis_h3_export_parquet()] does for a
#' `place_exact` collection exported in the same run: `release.json` gets the
#' `layers$place_exact` entry (the collection from its `meta.json`, plus the
#' layer's `rows`, `files` and `bytes` over every collection on disk), and,
#' with `manifest = TRUE`, `files.parquet` has its `place_exact` rows replaced by
#' one row per file on disk and `files$n_files` in `release.json` is updated.
#' The layer's `template`, `columns` and `note` are kept when `release.json` already has
#' them. Nothing else in the release is touched (`stats.parquet`, the other layers'
#' rows, `collection.json`), and running it again for the same `coll` gives the
#' same entries.
#'
#' Use it to add a collection after a release was built (for example the
#' gazetteer `places` sanctuaries, computed with `data-raw/run_place_exact.R`),
#' on a staging copy of the release: `release_dir` must hold `release.json`, and
#' `files.parquet` when `manifest = TRUE`, plus every collection the release
#' already lists (a collection listed in `release.json` but missing on disk is
#' kept in `collections` with a warning, and not counted in `rows`, `files`, `bytes`).
#'
#' @param release_dir the release directory (holding `release.json`, `files.parquet`
#'   and `place_exact/coll=<coll>/{indicators,years}.parquet`, `meta.json`).
#' @param coll the collection slug already written under `place_exact/`.
#' @param source optional text recorded as the collection's `source` (where the
#'   polygons came from); default: the existing entry's, else omitted.
#' @param manifest also update `files.parquet` (default `TRUE`).
#' @param compression Parquet compression of the rewritten `files.parquet`.
#'
#' @return invisibly, the paths of the files rewritten (`release.json`, and
#'   `files.parquet` with `manifest = TRUE`).
#' @concept analyze
#' @export
obis_h3_add_place_exact <- function(release_dir, coll, source = NULL, manifest = TRUE,
                                    compression = "zstd") {
  stopifnot(requireNamespace("DBI", quietly = TRUE),
            requireNamespace("duckdb", quietly = TRUE),
            requireNamespace("jsonlite", quietly = TRUE),
            is.character(release_dir), length(release_dir) == 1L, dir.exists(release_dir),
            is.character(coll), length(coll) == 1L, grepl("^[A-Za-z0-9._-]+$", coll),
            is.null(source) || (is.character(source) && length(source) == 1L),
            is.logical(manifest), length(manifest) == 1L, !is.na(manifest))
  rel   <- normalizePath(release_dir)
  f_js  <- file.path(rel, "release.json")
  f_man <- file.path(rel, "files.parquet")
  stopifnot("release_dir has no release.json" = file.exists(f_js),
            "release_dir has no files.parquet (manifest = FALSE skips it)" =
              !manifest || file.exists(f_man))
  d <- file.path(rel, "place_exact", paste0("coll=", coll))
  need <- file.path(d, c("indicators.parquet", "years.parquet", "meta.json"))
  if (!all(file.exists(need)))
    stop("missing under ", d, ": ", paste(basename(need)[!file.exists(need)], collapse = ", "))
  q <- function(x) gsub("'", "''", x)

  # every place_exact file on disk ----
  fx <- sort(list.files(file.path(rel, "place_exact"), pattern = "^(indicators|years)\\.parquet$",
                        recursive = TRUE))
  fx <- fx[grepl("^coll=[A-Za-z0-9._-]+/", fx)]
  paths <- file.path("place_exact", fx)
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  nr <- vapply(file.path(rel, paths), function(f) as.numeric(DBI::dbGetQuery(con, sprintf(
    "SELECT num_rows FROM parquet_file_metadata('%s') LIMIT 1", q(f)))$num_rows), numeric(1))
  on_disk <- data.frame(
    layer = "place_exact", path = paths, url_path = gsub("%", "%25", paths, fixed = TRUE),
    rows = unname(nr), bytes = as.numeric(file.size(file.path(rel, paths))),
    parent = NA_character_, stringsAsFactors = FALSE)

  # release.json ----
  js  <- jsonlite::read_json(f_js)   # lists stay arrays, scalars stay scalars when written back
  pxl <- .pe_layer_meta()
  lay <- js$layers$place_exact
  if (is.null(lay)) lay <- list(path = "place_exact", partitions = list("coll"))
  meta <- jsonlite::read_json(file.path(d, "meta.json"))
  ent  <- list(source = if (is.null(source)) lay$collections[[coll]]$source else source,
               places = as.integer(meta$n_places), records_in = meta$records_in,
               records_out = meta$records_out, records_total = meta$records_total,
               overlaps = meta$overlaps)
  lay$collections[[coll]] <- ent[!vapply(ent, is.null, logical(1))]
  listed <- names(lay$collections)
  gone <- setdiff(listed, unique(sub("^coll=([^/]+)/.*", "\\1", fx)))
  if (length(gone))
    warning("release.json lists collection(s) not on disk under ", file.path(rel, "place_exact"), ": ",
            paste(gone, collapse = ", "), call. = FALSE)
  # the layer's descriptive fields are kept when the release has them (a note may be edited by hand)
  if (is.null(lay$template)) lay$template <- as.list(pxl$template)
  if (is.null(lay$columns))  lay$columns  <- lapply(pxl$columns, as.list)
  if (is.null(lay$note))     lay$note     <- pxl$note
  lay$rows     <- sum(on_disk$rows)
  lay$files    <- nrow(on_disk)
  lay$bytes    <- sum(on_disk$bytes)
  added <- if (is.null(lay$added)) "added after the release was built" else lay$added
  tag   <- paste0("coll=", coll, " ")
  if (!grepl(tag, added, fixed = TRUE))
    added <- paste0(sub("[; ]*$", "", added), "; ", tag, "added ",
                    format(Sys.time(), "%Y-%m-%d", tz = "UTC"),
                    " by obis_h3_add_place_exact() ", .obisindicators_version())
  if (manifest)   # files.parquet now lists the layer
    added <- sub("the release files.parquet does not list it", "files.parquet lists it since this addition",
                 added, fixed = TRUE)
  lay$added <- added
  js$layers$place_exact <- lay

  # files.parquet ----
  out <- f_js
  if (manifest) {
    old <- DBI::dbGetQuery(con, sprintf("SELECT * FROM read_parquet('%s')", q(f_man)))
    keep <- old[old$layer != "place_exact", , drop = FALSE]
    new  <- rbind(keep[, names(on_disk)], on_disk)
    new  <- new[order(new$path), ]
    duckdb::duckdb_register(con, "add_pe_files", new)
    on.exit(duckdb::duckdb_unregister(con, "add_pe_files"), add = TRUE)
    f_tmp <- paste0(f_man, ".tmp")
    DBI::dbExecute(con, sprintf(
      "COPY (SELECT layer, path, url_path, rows::BIGINT AS rows, bytes::BIGINT AS bytes,
                    parent::VARCHAR AS parent FROM add_pe_files ORDER BY path)
       TO '%s' (FORMAT PARQUET, COMPRESSION %s);", q(f_tmp), compression))
    file.rename(f_tmp, f_man)
    if (!is.null(js$files)) js$files$n_files <- nrow(new) + 1L
    out <- c(f_js, f_man)
  }
  jsonlite::write_json(js, f_js, auto_unbox = TRUE, pretty = TRUE, digits = NA, null = "null")
  invisible(out)
}

# the release.json fields of the place_exact layer that do not depend on the collections
.pe_layer_meta <- function() {
  list(
    template = I(c("place_exact/coll=<coll>/indicators.parquet",
                   "place_exact/coll=<coll>/years.parquet")),
    columns  = list(
      indicators = I(c("place_id", "eov", "decade", "n", "sp", "shannon", "simpson", "es",
                       "hill_1", "hill_2", "bp", "density")),
      years      = I(c("place_id", "eov", "year", "n", "sp", "shannon", "simpson", "es",
                       "hill_1", "hill_2", "bp", "density"))),
    note = paste(
      "indicators of each place computed from the OBIS occurrences inside the true polygon",
      "(exact point-in-polygon, no H3), one row per place x eov ('all' | EOV) x decade",
      "(NULL = all years) in indicators.parquet and x year in years.parquet; n = records,",
      "sp = species, bp = Berger-Parker max(ni)/n, hill_1 = exp(shannon), hill_2 = 1/simpson,",
      "density = n / area_km2 (records per km2); es is NULL where n < esn. values only, no geometry."))
}

# helpers ----

# decades argument as a sorted integer vector (empty = none)
.pe_decades <- function(decades) {
  if (isTRUE(decades)) return(PLACE_EXACT_DECADES)
  if (is.null(decades) || isFALSE(decades)) return(integer(0))
  stopifnot(is.numeric(decades), !anyNA(decades), all(decades %% 10 == 0))
  sort(unique(as.integer(decades)))
}

# years argument: NULL = every year with records, integer(0) = none, else the years
.pe_years <- function(years) {
  if (isTRUE(years)) return(NULL)
  if (is.null(years) || isFALSE(years)) return(integer(0))
  stopifnot(is.numeric(years), !anyNA(years))
  sort(unique(as.integer(years)))
}

# resource guards, as build_obis_h3_duckdb()
.pe_setup <- function(con, memory_limit, threads, temp_dir, max_temp_dir_size) {
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
    DBI::dbExecute(con, glue::glue("SET max_temp_directory_size = '{max_temp_dir_size}';"))
  invisible(con)
}

# LOAD an extension, installing it first when it is not there yet (`ext` is a constant)
.pe_load_ext <- function(con, ext) {
  ok <- tryCatch({ DBI::dbExecute(con, paste0("LOAD ", ext, ";")); TRUE },
                 error = function(e) FALSE)
  if (!ok)
    tryCatch(DBI::dbExecute(con, paste0("INSTALL ", ext, "; LOAD ", ext, ";")),
             error = function(e)
               stop("cannot load the duckdb ", ext, " extension: ", conditionMessage(e), call. = FALSE))
  invisible(TRUE)
}

# places as a SELECT of (place_id, area_km2, geom GEOMETRY); registers a view for sf
.pe_places <- function(con, places, view) {
  if (inherits(places, "sf")) {
    stopifnot("`places` needs a `place_id` column" = "place_id" %in% names(places))
    crs <- sf::st_crs(places)
    if (!is.na(crs) && !(crs == sf::st_crs(4326))) places <- sf::st_transform(places, 4326)
    geom <- sf::st_geometry(places)
    df <- data.frame(
      place_id = as.character(places$place_id),
      wkb      = ifelse(sf::st_is_empty(geom), NA_character_, sf::st_as_binary(geom, hex = TRUE)),
      area_km2 = if ("area_km2" %in% names(places)) as.numeric(places$area_km2) else NA_real_,
      stringsAsFactors = FALSE)
    duckdb::duckdb_register(con, view, df)
    return(list(view = view, sql = glue::glue(
      "SELECT place_id, area_km2, ST_GeomFromHEXWKB(wkb) AS geom FROM {view}")))
  }
  stopifnot("`places` must be an sf object or GeoParquet path(s)" =
              is.character(places) && length(places) >= 1L)
  files <- paste(.h3t_sql_quote(path.expand(places)), collapse = ", ")
  rel   <- glue::glue("read_parquet([{files}])")
  desc  <- DBI::dbGetQuery(con, glue::glue("DESCRIBE SELECT * FROM {rel}"))
  gcol  <- intersect(c("geometry", "geom"), desc$column_name)[1]
  if (!"place_id" %in% desc$column_name || is.na(gcol))
    stop("`places` needs the columns `place_id` and `geometry`")
  gtype <- desc$column_type[desc$column_name == gcol]
  geom  <- if (grepl("^GEOMETRY", gtype)) sprintf('"%s"', gcol) else
    sprintf('ST_GeomFromWKB("%s")', gcol)
  area  <- if ("area_km2" %in% desc$column_name) "area_km2::DOUBLE" else "NULL::DOUBLE"
  list(view = character(0), sql = glue::glue(
    "SELECT place_id::VARCHAR AS place_id, {area} AS area_km2, {geom} AS geom FROM {rel}"))
}

# the occurrence source as SQL pieces (a registered data.frame, or read_parquet() with the
# schema probed from ONE file, nested `interpreted` struct or flat), as build_obis_h3_duckdb()
.pe_occ_source <- function(con, occ, view, s3_region, s3_anonymous) {
  if (is.data.frame(occ)) {
    cols <- names(occ)
    pfx  <- ""
    has_interpreted <- FALSE
    duckdb::duckdb_register(con, view, occ)
    from <- view
    vw   <- view
  } else {
    stopifnot("`occ` must be a data.frame or parquet path(s)/glob(s)" =
                is.character(occ) && length(occ) >= 1L)
    if (any(grepl("^(s3|https?)://", occ))) {
      .pe_load_ext(con, "httpfs")
      if (any(grepl("^s3://", occ))) {
        DBI::dbExecute(con, glue::glue("SET s3_region = '{s3_region}';"))
        if (s3_anonymous)
          DBI::dbExecute(con, "SET s3_access_key_id=''; SET s3_secret_access_key='';")
      }
    }
    globs <- paste(.h3t_sql_quote(path.expand(occ)), collapse = ", ")
    # no union_by_name: reading the schema of thousands of files can exhaust RAM
    from  <- glue::glue("read_parquet([{globs}])")
    occ   <- path.expand(occ)
    probe <- if (any(grepl("\\*", occ))) {
      ex <- Sys.glob(occ)
      if (length(ex) == 0) occ[1] else ex[1]
    } else occ[1]
    probe_rel <- glue::glue("read_parquet({.h3t_sql_quote(probe)})")
    top_cols  <- names(DBI::dbGetQuery(con, glue::glue("SELECT * FROM {probe_rel} LIMIT 0")))
    # OBIS open data nests the DwC fields in an `interpreted` struct; dropped/absence stay top-level
    has_interpreted <- "interpreted" %in% top_cols
    if (has_interpreted) {
      cols <- names(DBI::dbGetQuery(con, glue::glue("SELECT interpreted.* FROM {probe_rel} LIMIT 0")))
      pfx  <- "interpreted."
    } else {
      cols <- top_cols
      pfx  <- ""
    }
    vw <- character(0)
  }
  # DuckDB matches identifiers case-insensitively, R does not
  col_match <- function(x) {
    i <- match(tolower(x), tolower(cols))
    if (is.na(i)) NA_character_ else cols[i]
  }
  col_or_null <- function(x, type = "VARCHAR") {
    m <- col_match(x)
    if (!is.na(m)) paste0(pfx, sprintf('"%s"', m)) else sprintf("NULL::%s", type)
  }
  need <- vapply(c("decimalLongitude", "decimalLatitude", "species"),
                 function(x) !is.na(col_match(x)), logical(1))
  if (!all(need))
    stop("`occ` lacks the column(s): ", paste(names(need)[!need], collapse = ", "))
  where <- c(paste0(pfx, "species IS NOT NULL"),
             paste0(pfx, "decimalLatitude IS NOT NULL"),
             paste0(pfx, "decimalLongitude IS NOT NULL"))
  if (has_interpreted) {
    where <- c(where, "dropped IS NOT TRUE", "absence IS NOT TRUE")
  } else {
    if (!is.na(col_match("dropped"))) where <- c(where, "dropped IS NOT TRUE")
    if (!is.na(col_match("absence"))) where <- c(where, "absence IS NOT TRUE")
  }
  rec <- col_match("records")
  list(
    from    = from,
    view    = vw,
    lon     = paste0(pfx, "decimalLongitude"),
    lat     = paste0(pfx, "decimalLatitude"),
    species = paste0(pfx, "species"),
    aphiaid = col_or_null("aphiaid", "BIGINT"),
    has_aphiaid = !is.na(col_match("aphiaid")),
    year    = col_or_null("date_year", "SMALLINT"),
    records = if (!is.na(rec)) paste0("SUM(", pfx, sprintf('"%s"', rec), ")") else "COUNT(*)",
    where   = paste(where, collapse = "\n      AND "))
}

# EOV membership (eov, taxonID) from a data frame or a store connection's `eov` table
.pe_eov_membership <- function(eov) {
  if (inherits(eov, "DBIConnection")) {
    if (!.obis_has_table(eov, "eov")) stop("the store has no `eov` table (see obis_eov_bake())")
    eov <- DBI::dbGetQuery(eov, "SELECT eov, taxonID FROM eov")
  }
  stopifnot("`eov` must be NULL, a data frame (eov, taxonID) or a store connection" =
              is.data.frame(eov) && all(c("eov", "taxonID") %in% names(eov)))
  data.frame(eov = as.character(eov$eov), taxonID = as.numeric(eov$taxonID),
             stringsAsFactors = FALSE)
}
