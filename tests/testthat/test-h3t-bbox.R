# the {{bbox}} placeholder + spatial (res, lat, lng) clustering let the h3t tile
# server prune each tile's scan to its bbox instead of aggregating the whole
# globe. these tests pin (a) the SQL string wiring and (b) the correctness
# contract that pruning is *result-preserving*: a bbox-pruned scan followed by
# the server's outer centroid filter returns exactly the same cells/values as an
# unpruned scan restricted to the same bbox (no dropped or under-counted cells).

test_that("obis_h3t_sql()/obis_spue_sql() splice {{bbox}} only where lat/lng exist", {
  skip_if_not_installed("glue")

  # all-taxa idx_h3 path -> bbox present
  expect_true(grepl("{{bbox}}", obis_h3t_sql("n"), fixed = TRUE))
  expect_true(grepl("{{bbox}}", obis_h3t_sql("es"), fixed = TRUE))
  # live occ_h3 path (finer rank) -> bbox present
  expect_true(grepl("{{bbox}}", obis_h3t_sql("n", taxon = list(genus = "Gadus")),
                    fixed = TRUE))
  # precomputed per-taxon idx_h3_taxon path has no lat/lng -> NO bbox token
  expect_false(grepl("{{bbox}}", obis_h3t_sql("es", taxon = list(class = "Aves")),
                     fixed = TRUE))
  # SPUE live path -> bbox present
  expect_true(grepl("{{bbox}}", obis_spue_sql(2688, 1837), fixed = TRUE))

  # bbox_placeholder = "" disables the token (for direct execution: /h3, stats)
  expect_false(grepl("{{bbox}}", obis_h3t_sql("n", bbox_placeholder = ""),
                     fixed = TRUE))
  expect_false(grepl("{{bbox}}",
                     obis_h3t_sql("n", taxon = list(genus = "Gadus"),
                                  bbox_placeholder = ""), fixed = TRUE))
  expect_false(grepl("{{bbox}}", obis_spue_sql(2688, 1837, bbox_placeholder = ""),
                     fixed = TRUE))
})

test_that("the store materializes lat/lng and bbox pruning is result-preserving", {
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

  # small reproducible subset; synthesize a genus so the live occ_h3 path (a
  # non-precomputed rank) is exercised alongside the all-taxa idx_h3 path.
  set.seed(42)
  occ <- occ_SAtlantic[sample(nrow(occ_SAtlantic), 1e5), ]
  sp  <- sort(unique(occ$species))
  occ$genus <- paste0("Genus", (match(occ$species, sp) %% 4L) + 1L)

  db <- tempfile(fileext = ".duckdb")
  build_obis_h3_duckdb(occ, db, overwrite = TRUE)
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db, read_only = TRUE)
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(db) }, add = TRUE)
  DBI::dbExecute(con, "LOAD h3;")

  # lat/lng columns are materialized on both bbox-pruned layers
  for (tbl in c("occ_h3", "idx_h3")) {
    cols <- names(DBI::dbGetQuery(con, glue::glue("SELECT * FROM {tbl} LIMIT 0")))
    expect_true(all(c("lat", "lng") %in% cols),
                info = glue::glue("{tbl} must carry lat/lng"))
  }

  # server-side geometry: buffers that guarantee the inner (base-cell) filter is
  # a superset of the outer (display-cell centroid) filter. mirrors
  # h3t_query.h3_edge_length_deg + the tile route's 1.5x / 3x buffers.
  edge_deg <- function(r) 1106.54 / (sqrt(7)^r) / 111.32
  inner_pred <- function(lm, am, lM, aM, buf) sprintf(
    paste0("AND lat BETWEEN %.10f AND %.10f ",
           "AND (lng BETWEEN %.10f AND %.10f ",
           "OR lng + 360 BETWEEN %.10f AND %.10f ",
           "OR lng - 360 BETWEEN %.10f AND %.10f)"),
    am - buf, aM + buf, lm - buf, lM + buf, lm - buf, lM + buf, lm - buf, lM + buf)

  # data extent -> a sub-bbox (inner half) that actually contains cells
  ext <- DBI::dbGetQuery(con, "
    SELECT MIN(lng) lo_lng, MAX(lng) hi_lng, MIN(lat) lo_lat, MAX(lat) hi_lat
    FROM occ_h3 WHERE res = 7")
  qx <- function(lo, hi, f) lo + (hi - lo) * f
  lm <- qx(ext$lo_lng, ext$hi_lng, 0.25); lM <- qx(ext$lo_lng, ext$hi_lng, 0.75)
  am <- qx(ext$lo_lat, ext$hi_lat, 0.25); aM <- qx(ext$lo_lat, ext$hi_lat, 0.75)

  # run a query and tag each display cell with its centroid for the outer filter
  run <- function(sql) DBI::dbGetQuery(con, glue::glue(
    "SELECT h3_h3_to_string(cell_id) AS cell, value, n,
            h3_cell_to_lng(cell_id) AS clng, h3_cell_to_lat(cell_id) AS clat
     FROM ({sql}) q"))

  # assert: {pruned then outer-filtered} == {unpruned then outer-filtered}
  check_preserving <- function(indicator, taxon, res) {
    ib  <- edge_deg(res) * 3.0    # inner buffer (server tile route)
    ob  <- edge_deg(res) * 1.5    # outer buffer (wrap_tile_sql)
    common <- list(indicator = indicator, taxon = taxon,
                   res_placeholder = as.character(res))
    pruned <- do.call(obis_h3t_sql, c(common,
      list(bbox_placeholder = inner_pred(lm, am, lM, aM, ib))))
    full   <- do.call(obis_h3t_sql, c(common, list(bbox_placeholder = "")))

    dp <- run(pruned); df <- run(full)
    outer <- function(d) d[d$clng >= lm - ob & d$clng <= lM + ob &
                           d$clat >= am - ob & d$clat <= aM + ob, ]
    a <- outer(dp); b <- outer(df)
    a <- a[order(a$cell), ]; b <- b[order(b$cell), ]

    expect_gt(nrow(b), 0)                                  # bbox has cells
    expect_identical(a$cell, b$cell)                       # same cell set
    expect_equal(a$value, b$value, tolerance = 1e-9)       # identical values
    expect_equal(a$n,     b$n)
  }

  # idx_h3 all-taxa path (cell_id == display cell)
  check_preserving("n",  NULL, res = 5L)
  check_preserving("es", NULL, res = 4L)
  # live occ_h3 path where the base tier (5) is finer than the display res (4):
  # exercises the base->parent buffer guarantee
  top_g <- DBI::dbGetQuery(con, "
    SELECT genus FROM occ_h3 WHERE res = 7 AND genus IS NOT NULL
    GROUP BY 1 ORDER BY COUNT(*) DESC LIMIT 1")$genus
  check_preserving("n", list(genus = top_g), res = 4L)
})
