# the h3t tile server prunes each tile by injecting `hex_prune IN (<the tile's
# covering res-H3T_PRUNE_RES cells>)` (derived from z/x/y) into the idx_h3 /
# occ_h3 scan. clients emit plain per-resolution SELECTs. these tests pin (a)
# that the client SQL stays bbox-free and (b) the correctness contract that
# pruning is *result-preserving*: a hex_prune-pruned scan followed by the
# server's outer centroid filter returns exactly the same cells/values as an
# unpruned scan restricted to the same tile bbox.

test_that("obis_h3t_sql()/obis_spue_sql() emit plain per-res SELECTs (no client bbox)", {
  skip_if_not_installed("glue")

  for (ind in c("es", "sp", "shannon", "n")) {
    s <- obis_h3t_sql(ind)
    expect_match(s, "FROM idx_h3")                     # precomputed all-taxa
    expect_true(grepl("{{res}}", s, fixed = TRUE))     # zoom placeholder kept
    expect_false(grepl("{{bbox}}", s, fixed = TRUE))   # no client bbox token
    expect_false(grepl("hex_prune", s))                # server injects it, not the client
  }
  expect_match(obis_h3t_sql("n", taxon = list(genus = "Gadus")), "occ_h3")
  expect_false(grepl("hex_prune", obis_spue_sql(2688, 1837)))
  expect_false(grepl("{{bbox}}", obis_spue_sql(2688, 1837), fixed = TRUE))

  # the old client-side bbox placeholder argument is gone
  expect_error(obis_h3t_sql("n", bbox_placeholder = ""), "unused")
  expect_error(obis_spue_sql(1, 2, bbox_placeholder = ""), "unused")
})

test_that("the store materializes hex_prune and pruning is result-preserving", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("glue")

  h3_ok <- tryCatch({
    c0 <- DBI::dbConnect(duckdb::duckdb())
    on.exit(DBI::dbDisconnect(c0, shutdown = TRUE), add = TRUE)
    DBI::dbExecute(c0, "INSTALL h3 FROM community; LOAD h3;")
    TRUE
  }, error = function(e) FALSE)
  skip_if(!h3_ok, "duckdb h3 community extension unavailable")

  set.seed(42)
  occ <- occ_SAtlantic[sample(nrow(occ_SAtlantic), 1e5), ]
  sp  <- sort(unique(occ$species))
  occ$genus <- paste0("Genus", (match(occ$species, sp) %% 4L) + 1L)

  db <- tempfile(fileext = ".duckdb")
  build_obis_h3_duckdb(occ, db, overwrite = TRUE)
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db, read_only = TRUE)
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(db) }, add = TRUE)
  DBI::dbExecute(con, "LOAD h3;")

  # hex_prune materialized, lat/lng absent, on both pruned layers
  for (tbl in c("occ_h3", "idx_h3")) {
    cols <- tolower(names(DBI::dbGetQuery(con, glue::glue("SELECT * FROM {tbl} LIMIT 0"))))
    expect_true("hex_prune" %in% cols, info = glue::glue("{tbl} must carry hex_prune"))
    expect_false(any(c("lat", "lng") %in% cols))
  }
  # hex_prune is the coarse H3 parent at H3T_PRUNE_RES (parity with the server)
  bad <- DBI::dbGetQuery(con, glue::glue(
    "SELECT COUNT(*) n FROM occ_h3
      WHERE hex_prune <> CAST(h3_cell_to_parent(cell_id, LEAST(res, {H3T_PRUNE_RES})) AS BIGINT)"))$n
  expect_identical(as.numeric(bad), 0)

  # a sub-bbox of the data extent
  ext <- DBI::dbGetQuery(con, "
    SELECT MIN(h3_cell_to_lng(cell_id)) lo_lng, MAX(h3_cell_to_lng(cell_id)) hi_lng,
           MIN(h3_cell_to_lat(cell_id)) lo_lat, MAX(h3_cell_to_lat(cell_id)) hi_lat
    FROM occ_h3 WHERE res = 7")
  qx <- function(lo, hi, f) lo + (hi - lo) * f
  lm <- qx(ext$lo_lng, ext$hi_lng, 0.3); lM <- qx(ext$lo_lng, ext$hi_lng, 0.7)
  am <- qx(ext$lo_lat, ext$hi_lat, 0.3); aM <- qx(ext$lo_lat, ext$hi_lat, 0.7)

  # the tile's covering cells at H3T_PRUNE_RES, exactly as the server computes
  # them from z/x/y — buffered by ~2 res-H3T_PRUNE_RES edges so it's a superset
  # of any cell whose display centroid lands in the (unbuffered) bbox.
  edge_deg <- function(r) 1106.54 / (sqrt(7)^r) / 111.32
  b   <- edge_deg(H3T_PRUNE_RES) * 2
  wkt <- sprintf("POLYGON((%f %f, %f %f, %f %f, %f %f, %f %f))",
                 lm - b, am - b, lM + b, am - b, lM + b, aM + b, lm - b, aM + b, lm - b, am - b)
  # covering cells kept as a SQL subquery: res-H3T_PRUNE_RES ids exceed R's
  # 2^53 double precision, so round-tripping them through R would corrupt the
  # IN-list. The server computes them in Python (arbitrary-precision ints) and
  # injects integer literals — same set, no precision loss.
  cover_ok <- tryCatch(
    DBI::dbGetQuery(con, glue::glue(
      "SELECT COUNT(*) n FROM (SELECT UNNEST(h3_polygon_wkt_to_cells('{wkt}', {H3T_PRUNE_RES})) c)"))$n > 0,
    error = function(e) FALSE)
  skip_if(!isTRUE(cover_ok), "duckdb h3 polygon_wkt_to_cells unavailable")
  cover_in <- glue::glue(
    "hex_prune IN (SELECT UNNEST(h3_polygon_wkt_to_cells('{wkt}', {H3T_PRUNE_RES}))::BIGINT)")

  # tag each output cell with its display centroid, then apply the OUTER filter
  # (unbuffered bbox) in R and compare pruned vs unpruned.
  run <- function(sql) DBI::dbGetQuery(con, glue::glue(
    "SELECT h3_h3_to_string(cell_id) AS cell, value, n,
            h3_cell_to_lng(cell_id) AS clng, h3_cell_to_lat(cell_id) AS clat
     FROM ({sql}) q"))
  outer <- function(d) {
    d <- d[d$clng >= lm & d$clng <= lM & d$clat >= am & d$clat <= aM, ]
    d[order(d$cell), ]
  }
  check <- function(full, pruned) {
    a <- outer(run(pruned)); b <- outer(run(full))
    expect_gt(nrow(b), 0)
    expect_identical(a$cell, b$cell)
    expect_equal(a$value, b$value, tolerance = 1e-9)
    expect_equal(a$n, b$n)
  }

  # idx_h3 all-taxa path (cell_id == display cell), res 5
  check(
    "SELECT cell_id, n AS value, n FROM idx_h3 WHERE res = 5",
    glue::glue("SELECT cell_id, n AS value, n FROM idx_h3 WHERE res = 5 AND {cover_in}"))
  check(
    "SELECT cell_id, es AS value, n FROM idx_h3 WHERE res = 4",
    glue::glue("SELECT cell_id, es AS value, n FROM idx_h3 WHERE res = 4 AND {cover_in}"))

  # live occ_h3 path (genus filter), display res 5 -> tier 5 (base finer than
  # display for res 4 below): the prune predicate goes on the occ_h3 scan.
  g <- DBI::dbGetQuery(con, "
    SELECT genus FROM occ_h3 WHERE res = 7 AND genus IS NOT NULL
    GROUP BY 1 ORDER BY COUNT(*) DESC LIMIT 1")$genus
  occ_sql <- function(prune) glue::glue(
    "WITH src AS (
       SELECT CAST(h3_cell_to_parent(cell_id, 4) AS BIGINT) AS cell_id, species, SUM(records) AS ni
       FROM occ_h3 WHERE res = 5 AND genus = '{g}' {prune}
       GROUP BY 1, 2)
     SELECT cell_id, SUM(ni) AS value, SUM(ni) AS n FROM src GROUP BY cell_id")
  check(occ_sql(""), occ_sql(glue::glue("AND {cover_in}")))
})
