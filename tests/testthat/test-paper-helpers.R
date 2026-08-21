# analysis-side helpers behind the paper figures: store/query, scale curves,
# rank-vs-subtree, EOV totals, SPUE cells + raster comparison, periods, places,
# hex polygons. each asserts an exact expected value on the synthetic fixture.

skip_paper <- function() {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("glue")
  skip_if_not_installed("gsl")
  skip_if(!h3_ext_ok(), "duckdb h3 community extension unavailable")
}

test_that("h3_res_table() carries the canonical areas", {
  t <- h3_res_table(c(3, 7))
  expect_equal(t$res, c(3L, 7L))
  expect_equal(t$area_km2, c(12393.435, 5.161), tolerance = 1e-6)
  expect_equal(nrow(h3_res_table()), 11)
})

test_that("obis_store_connect() loads h3 and refuses a missing path", {
  skip_paper()
  expect_error(obis_store_connect(path = tempfile(fileext = ".duckdb")), "store not found")
  fx <- make_paper_fixture()
  DBI::dbDisconnect(fx$con, shutdown = TRUE)
  con <- obis_store_connect(fx$db, install_h3 = FALSE)
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)
  expect_true(DBI::dbIsValid(con))
  # h3 is loaded: a string conversion round-trips
  expect_equal(
    DBI::dbGetQuery(con, "SELECT h3_h3_to_string(h3_string_to_h3('8344a5fffffffff')) AS s")$s,
    "8344a5fffffffff")
})

test_that("obis_store_stats() reports tables, totals and cells by res", {
  skip_paper()
  fx <- make_paper_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  s <- obis_store_stats(con)
  expect_setequal(s$tables$table, c("taxon", "occ_h3", "idx_h3", "eov", "idx_h3_eov"))
  tot <- stats::setNames(s$totals$value, s$totals$metric)
  expect_equal(as.numeric(tot[["records"]]), 805)       # 200 + 45 + 260 + 300
  expect_equal(as.numeric(tot[["species"]]), 3)
  expect_equal(as.numeric(tot[["cells_base"]]), 4)
  expect_equal(as.numeric(tot[["year_min"]]), 1975)
  expect_equal(s$cells_by_res$n_cells[s$cells_by_res$res == 7], 4)
  expect_equal(s$cells_by_res$n_cells[s$cells_by_res$res == 3], 3)   # A+B merge
  expect_true("area_km2" %in% names(s$cells_by_res))
})

test_that("obis_h3t_query() binds {{res}} and keys on the hex string", {
  skip_paper()
  fx <- make_paper_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  d <- obis_h3t_query(con, obis_h3t_sql("n"), res = 7)
  expect_named(d, c("cell", "value", "n"))
  expect_equal(nrow(d), 4)
  expect_type(d$cell, "character")
  expect_equal(sort(as.numeric(d$value)), c(45, 200, 260, 300))
})

test_that("obis_cell_indicators(): precomputed layers agree with the live path", {
  skip_paper()
  fx <- make_paper_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  for (r in c(3L, 7L)) {
    pre  <- obis_cell_indicators(con, r)                     # idx_h3
    live <- obis_cell_indicators(con, r, live = TRUE)         # occ_h3 aggregation
    m <- merge(pre, live, by = "cell", suffixes = c(".pre", ".live"))
    expect_equal(nrow(m), nrow(pre))
    expect_equal(as.numeric(m$n.pre),  as.numeric(m$n.live))
    expect_equal(as.numeric(m$sp.pre), as.numeric(m$sp.live))
    expect_equal(m$es.pre, m$es.live, tolerance = 1e-3)
    expect_equal(m$shannon.pre, m$shannon.live, tolerance = 1e-8)

    epre  <- obis_cell_indicators(con, r, eov = "seaTurtles")            # idx_h3_eov
    elive <- obis_cell_indicators(con, r, eov = "seaTurtles", live = TRUE)
    em <- merge(epre, elive, by = "cell", suffixes = c(".pre", ".live"))
    expect_equal(nrow(em), nrow(epre))
    expect_equal(as.numeric(em$n.pre), as.numeric(em$n.live))
    expect_equal(em$es.pre, em$es.live, tolerance = 1e-3)
  }
  # the bird cell never enters the turtle EOV
  e7 <- obis_cell_indicators(con, 7, eov = "seaTurtles")
  expect_equal(sort(as.numeric(e7$n)), c(45, 200, 260))
  # an AphiaID subtree at an intermediate rank (family Cheloniidae) = same cells
  a7 <- obis_cell_indicators(con, 7, aphiaid = 987095)
  expect_equal(sort(as.numeric(a7$n)), c(45, 200, 260))
  expect_error(obis_cell_indicators(con, 7, eov = "seaTurtles", aphiaid = 1), "one of")
})

test_that("calc_scale_curves(): cells fall and eligibility rises as hexes coarsen", {
  skip_paper()
  fx <- make_paper_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  sc <- calc_scale_curves(con, res = c(3L, 7L), eov = "seaTurtles", esn = 50L, group = "turtles")
  expect_equal(sc$group, c("turtles", "turtles"))
  expect_equal(sc$res, c(3L, 7L))
  # res 7: A(200) B(45) C(260) -> 3 cells, 2 of 3 ES-eligible; res 3: A+B merge -> 2 cells, both eligible
  expect_equal(sc$n_cells, c(2, 3))
  expect_equal(sc$frac_eligible, c(1, 2/3))
  expect_equal(sc$records, c(505, 505))
  expect_equal(sc$n_cells_all, c(3, 4))                 # idx_h3 occupied cells incl. the bird
  expect_equal(sc$frac_n_ge_100, c(1, 2/3))
  expect_equal(sc$area_km2, h3_res_table(c(3, 7))$area_km2)
  expect_true(all(!is.na(sc$median_es)))
})

test_that("calc_spue_scale() tracks the thinning effort denominator", {
  skip_paper()
  fx <- make_paper_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  # target Chelonia mydas (987097) over effort Cheloniidae (987095)
  ss <- calc_spue_scale(con, 987097, 987095, res = c(3L, 7L), floors = c(50L, 250L))
  expect_equal(ss$n_cells_effort, c(2, 3))
  expect_equal(ss$effort_records, c(505, 505))
  # every effort cell has the target here, so frac_present = 1
  expect_equal(ss$frac_present, c(1, 1))
  # res 7 effort counts 200, 45, 260 -> 1/3 below 50; 2/3 below 250
  expect_equal(ss$frac_effort_lt_50[2], 1/3)
  expect_equal(ss$frac_effort_lt_250[2], 2/3)
})

test_that("calc_rank_vs_subtree(): a wrong-rank name finds nothing by column, everything by subtree", {
  skip_paper()
  fx <- make_paper_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  presets <- data.frame(
    label   = c("turtles-wrong-rank", "turtles-right-rank", "birds"),
    rank    = c("class", "order", "class"),
    name    = c("Testudines", "Testudines", "Aves"),
    aphiaid = c(2689L, 2689L, 1836L),
    stringsAsFactors = FALSE)
  rv <- calc_rank_vs_subtree(con, presets)
  expect_equal(rv$records_rank, c(0, 505, 300))
  expect_equal(rv$records_tree, c(505, 505, 300))
  expect_equal(rv$species_tree, c(2, 2, 1))
  expect_equal(rv$ratio, c(0, 1, 1))
  # the shipped presets are the app's eight groups with their seed ids
  p <- obis_rank_presets()
  expect_equal(nrow(p), 8)
  expect_equal(p$aphiaid[p$name == "Actinopterygii"], 10194L)
  expect_equal(p$aphiaid[p$name == "Aves"], 1836L)
})

test_that("calc_eov_totals() / compare_eov_totals() quantify a taxonomy gap", {
  skip_paper()
  fx <- make_paper_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  after <- calc_eov_totals(con, eov = c("seaTurtles", "seabirds"))
  expect_equal(after$records[after$eov == "seaTurtles"], 505)
  expect_equal(after$species[after$eov == "seaTurtles"], 2)
  expect_equal(after$cells[after$eov == "seaTurtles"], 3)
  expect_equal(after$pct_records[after$eov == "seabirds"], 100 * 300 / 805)

  # the live (no `eov` table) path must agree with the baked membership
  DBI::dbExecute(con, "ALTER TABLE eov RENAME TO eov_bak;")
  live <- calc_eov_totals(con, eov = c("seaTurtles", "seabirds"))
  DBI::dbExecute(con, "ALTER TABLE eov_bak RENAME TO eov;")
  expect_equal(live$records, after$records)

  # simulate the pre-gap-fill store: Caretta caretta missing from taxon
  DBI::dbExecute(con, "DELETE FROM taxon WHERE taxonID = 987098;")
  DBI::dbExecute(con, "DELETE FROM eov WHERE taxonID = 987098;")
  before <- calc_eov_totals(con, eov = c("seaTurtles", "seabirds"))
  cmp <- compare_eov_totals(before, after)
  t <- cmp[cmp$eov == "seaTurtles", ]
  expect_equal(t$records_before, 225)           # 120 + 45 + 60
  expect_equal(t$records_after, 505)
  expect_equal(t$records_pct, 100 * 280 / 225)
  expect_equal(cmp$records_delta[cmp$eov == "seabirds"], 0)
})

test_that("calc_spue_cells() returns target/effort counts per cell", {
  skip_paper()
  fx <- make_paper_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  s7 <- calc_spue_cells(con, 987097, 987095, res = 7)
  expect_named(s7, c("cell", "spue", "effort", "target"))
  expect_equal(nrow(s7), 3)
  expect_equal(sort(s7$effort), c(45, 200, 260))
  expect_equal(sort(s7$target), c(45, 60, 120))
  expect_equal(s7$spue, s7$target / s7$effort, tolerance = 1e-9)
})

test_that("h3_raster_to_cells() + compare_spue_sdm() agree on a synthetic gradient", {
  skip_paper()
  skip_if_not_installed("terra")
  fx <- make_paper_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  # a 0.05-degree raster whose value is the latitude (monotone north)
  r <- terra::rast(xmin = -70, xmax = -40, ymin = 0, ymax = 30, resolution = 0.05,
                   crs = "EPSG:4326")
  terra::values(r) <- terra::yFromCell(r, seq_len(terra::ncell(r)))

  cells <- paper_fixture_cells(con)
  # centres: res-3 hexes (~12,000 km2) hold many 0.05-deg pixels
  hc <- h3_raster_to_cells(r, res = 3, method = "centers")
  a3 <- h3::h3_to_parent(cells$cell[cells$name == "A"], 3)
  expect_true(a3 %in% hc$cell)
  expect_gt(hc$n_px[hc$cell == a3], 50)
  expect_equal(hc$value[hc$cell == a3], 10, tolerance = 0.5)
  # centroids: sampled value is the hex centroid latitude
  hs <- h3_raster_to_cells(r, res = 7, cells = cells$cell[cells$name %in% c("A", "C")],
                           method = "centroids")
  expect_equal(hs$value, c(10, 20), tolerance = 0.05)
  expect_equal(hs$n_px, c(1L, 1L))
  expect_error(h3_raster_to_cells(r, 7, method = "centroids"), "cells")
  # auto: coarse -> centres, fine with cells -> centroids
  expect_gt(nrow(h3_raster_to_cells(r, 2)), 0)

  # comparison: SPUE of Caretta over Cheloniidae at res 7 is 80/200 (A), 0 (B), 200/260 (C)
  sp <- calc_spue_cells(con, 987098, 987095, res = 7)
  sd <- h3_raster_to_cells(r, res = 7, cells = sp$cell, method = "centroids")
  cmp <- compare_spue_sdm(sp, sd, min_effort = 40L, n_bins = 2L)
  expect_equal(cmp$stats$n_cells, 3)
  expect_equal(cmp$stats$frac_present, 2/3)
  # higher SPUE at higher latitude here -> positive rank correlation
  expect_gt(cmp$stats$rho, 0)
  expect_setequal(cmp$calib$bin, c(0, 1, 2))
  expect_equal(cmp$calib$n_cells[cmp$calib$bin == 0], 1)
  # effort gate drops cell B (45 records) when raised
  expect_equal(compare_spue_sdm(sp, sd, min_effort = 100L)$stats$n_cells, 2)
})

test_that("calc_period_indicators() / calc_period_change() split by decade", {
  skip_paper()
  fx <- make_paper_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  pd <- calc_period_indicators(con, res = 3L, eov = "seaTurtles",
                               starts = c(1970L, 2010L), esn = 50L)
  expect_named(pd, c("period", "cell", "n", "sp", "es"))
  # 1970s: Caretta only -> A+B cell 80, C 200 ; 2010s: Chelonia only -> A+B 165, C 60
  p70 <- pd[pd$period == 1970, ]; p10 <- pd[pd$period == 2010, ]
  expect_equal(sort(as.numeric(p70$n)), c(80, 200))
  expect_equal(sort(as.numeric(p10$n)), c(60, 165))
  expect_true(all(as.numeric(pd$sp) == 1))

  ch <- calc_period_change(pd, from = 1970, to = 2010, esn = 50L, indicator = "es")
  # both cells reliable (>= 50) in both decades; single species -> ES50 = 1 -> delta 0
  expect_equal(ch$coverage$both, 2)
  expect_equal(ch$cells$delta, c(0, 0))
  # esn = 100: 1970s A+B (80) and 2010s C (60) fall below -> no cell reliable in both
  ch2 <- calc_period_change(pd, 1970, 2010, esn = 100L)
  expect_equal(ch2$coverage$both, 0)
  expect_equal(ch2$coverage$only_from, 1)       # C (200 in the 1970s)
  expect_equal(ch2$coverage$only_to, 1)         # A+B (165 in the 2010s)

  empty <- calc_period_indicators(con, res = 3L, eov = "seaTurtles", starts = 1900L)
  expect_equal(nrow(empty), 0)
})

test_that("calc_place_indicators() rolls cells up to polygons with the reference math", {
  skip_paper()
  fx <- make_paper_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  box <- function(xmin, ymin, xmax, ymax)
    sf::st_as_sfc(sf::st_bbox(c(xmin = xmin, ymin = ymin, xmax = xmax, ymax = ymax),
                              crs = sf::st_crs(4326)))
  places <- sf::st_sf(
    name = c("AB", "C", "empty"),
    geometry = c(box(-51, 9, -49, 11), box(-61, 19, -59, 21), box(0, 0, 1, 1)))

  pc <- place_cells(places, "name", res = 5)
  expect_true(all(c("AB", "C", "empty") %in% pc$place))
  expect_true(all(nchar(pc$cell) == 15))

  pi <- calc_place_indicators(con, places, "name", res = 5, eov = "seaTurtles")
  ab <- pi[pi$place == "AB", ]; cc <- pi[pi$place == "C", ]; em <- pi[pi$place == "empty", ]
  expect_equal(ab$n, 245)                  # 120 + 80 + 45
  expect_equal(ab$sp, 2)
  expect_equal(cc$n, 260)
  expect_equal(em$n_cells_occupied, 0)
  expect_true(is.na(em$n))
  # matches calc_indicators() on the same species totals (the reference)
  ref <- calc_indicators(data.frame(
    cell = c("AB", "AB", "C", "C"), species = c("Chelonia mydas", "Caretta caretta",
    "Caretta caretta", "Chelonia mydas"), records = c(165, 80, 200, 60)), esn = 50)
  expect_equal(ab$es, ref$es[ref$cell == "AB"], tolerance = 1e-9)
  expect_equal(cc$shannon, ref$shannon[ref$cell == "C"], tolerance = 1e-9)
  # the bird cell (40, 60) is outside every place, and the year filter applies
  p75 <- calc_place_indicators(con, places, "name", res = 5, eov = "seaTurtles",
                               years = c(1970, 1979))
  expect_equal(p75$n[p75$place == "AB"], 80)
  expect_error(calc_place_indicators(con, places[3, ], "name", res = 7), NA)
})

test_that("hex_sf() / gmap_cells() build polygons for arbitrary cells", {
  skip_paper()
  fx <- make_paper_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  d <- obis_cell_indicators(con, 5)
  s <- hex_sf(d$cell)
  expect_s3_class(s, "sf")
  expect_equal(nrow(s), nrow(d))
  expect_equal(s$cell, d$cell)
  expect_true(all(sf::st_is_valid(s)))
  p <- gmap_cells(d, "n", label = "records", mask = d$n >= 50)
  expect_s3_class(p, "ggplot")
})

test_that("obis_bench() times every query and obis_bench_queries() covers the four paths", {
  skip_paper()
  fx <- make_paper_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  q <- obis_bench_queries(res = 3L, eov = "seaTurtles", num_aphiaid = 987097L,
                          den_aphiaid = 987095L)
  expect_length(q, 4)
  expect_match(q[[1]], "idx_h3 WHERE")
  expect_match(q[[2]], "idx_h3_eov")
  expect_match(q[[3]], "WITH RECURSIVE")
  expect_match(q[[4]], "den_tree")
  b <- obis_bench(con, q, reps = 2L)
  expect_equal(b$label, names(q))
  expect_true(all(b$rows > 0))
  expect_true(all(b$cold_s >= 0 & b$warm_s >= 0))
})

test_that("plot_scale_curves() / plot_spue_sdm() return ggplots", {
  sc <- data.frame(group = rep(c("a", "b"), each = 3), res = rep(1:3, 2),
                   n_cells = c(10, 60, 400, 5, 30, 200), median_n = c(900, 130, 20, 700, 100, 15),
                   frac_eligible = c(1, .8, .3, 1, .7, .2), median_es = c(30, 25, 20, 28, 22, 18))
  expect_s3_class(plot_scale_curves(sc), "ggplot")
  cmp <- list(stats = data.frame(rho = .5, n_cells = 30L),
              calib = data.frame(bin = 0:2, n_cells = c(10, 10, 10), spue_mean = c(0, .1, .4),
                                 sdm_mean = c(.2, .4, .6), sdm_sd = c(.1, .1, .1)))
  expect_s3_class(plot_spue_sdm(cmp), "ggplot")
})
