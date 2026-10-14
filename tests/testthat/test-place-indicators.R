# obis_place_indicators(): per-place indicators pooled from area-weighted H3
# cells (gazetteer membership: place_id, h3, share). each rule gets a small
# synthetic fixture with hand-computed expectations.

# res-7 cells X, Y, Z (far apart) and W (no records):
#   X: A 40 (2015), B 20 (1975)
#   Y: A 30 (2015), C 10 (2015)
#   Z: B 50 (1985)
# eov table: fish = {A, C}, seabirds = {B}
make_place_fixture <- function() {
  con <- DBI::dbConnect(duckdb::duckdb())
  DBI::dbExecute(con, "LOAD h3;")
  DBI::dbExecute(con, "
    CREATE TABLE pts AS SELECT * FROM (VALUES
      ('X', 10.0, -50.0), ('Y', 20.0, -60.0), ('Z', 40.0, 60.0), ('W', -30.0, 10.0)
    ) t(name, lat, lng);")
  DBI::dbExecute(con, "
    CREATE TABLE occ_base AS
    SELECT CAST(h3_latlng_to_cell(p.lat, p.lng, 7) AS BIGINT) AS cell_id, o.*
    FROM (VALUES
      ('X', 1, 'A', 2015, 40), ('X', 2, 'B', 1975, 20),
      ('Y', 1, 'A', 2015, 30), ('Y', 3, 'C', 2015, 10),
      ('Z', 2, 'B', 1985, 50)
    ) o(name, aphiaid, species, date_year, records)
    JOIN pts p USING (name);")
  DBI::dbExecute(con, "
    CREATE TABLE occ_h3 (
      res UTINYINT, cell_id BIGINT, aphiaid BIGINT, species VARCHAR,
      date_year SMALLINT, records BIGINT);")
  for (r in c(3L, 5L, 7L))
    DBI::dbExecute(con, sprintf("
      INSERT INTO occ_h3
      SELECT %d, CAST(h3_cell_to_parent(cell_id, %d) AS BIGINT), aphiaid, species,
             date_year, SUM(records)
      FROM occ_base GROUP BY ALL;", r, r))
  DBI::dbExecute(con, "
    CREATE TABLE eov AS SELECT * FROM (VALUES
      ('fish', 1::BIGINT), ('fish', 3::BIGINT), ('seabirds', 2::BIGINT)) t(eov, taxonID);")
  cells <- DBI::dbGetQuery(con, "
    SELECT name, h3_h3_to_string(h3_latlng_to_cell(lat, lng, 7)) AS h3 FROM pts")
  list(con = con, cell = stats::setNames(cells$h3, cells$name),
       occ = DBI::dbGetQuery(con, "SELECT name, species, date_year, records::DOUBLE AS records FROM occ_base"))
}

memb <- function(cell, place_id, name, share)
  data.frame(place_id = place_id, h3 = unname(cell[name]), share = share,
             stringsAsFactors = FALSE)

# calc_indicators() on hand-weighted counts, one "cell" per place
ref_ind <- function(cell, species, records)
  as.data.frame(calc_indicators(
    data.frame(cell = cell, species = species, records = records), esn = 50))

test_that("pooled area-weighted indicators equal calc_indicators() on weighted counts", {
  skip_if_not_installed("DBI"); skip_if_not_installed("duckdb"); skip_if_not_installed("gsl")
  skip_if(!h3_ext_ok(), "duckdb h3 community extension unavailable")
  fx <- make_place_fixture(); con <- fx$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  # P1 = X (1) + Y (0.5) + W (empty); P2 = Y (0.25) + Z (1)
  m <- rbind(memb(fx$cell, "P1", c("X", "Y", "W"), c(1, 0.5, 1)),
             memb(fx$cell, "P2", c("Y", "Z"), c(0.25, 1)))
  got <- obis_place_indicators(con, m, decades = FALSE, eov = FALSE)
  expect_equal(names(got), c("place_id", "layer", "key", "decade", "n", "sp", "shannon",
                             "simpson", "es", "cells", "area"))
  expect_equal(got$place_id, c("P1", "P2"))
  expect_equal(got$layer, c("all", "all"))
  expect_equal(got$key, c("", ""))
  expect_true(all(is.na(got$decade)))

  # by hand: P1 A = 40 + 0.5 * 30 = 55, B = 20, C = 0.5 * 10 = 5 (n 80)
  #          P2 A = 0.25 * 30 = 7.5, C = 2.5, B = 50          (n 60)
  expect_equal(got$n, c(80, 60))
  expect_equal(got$sp, c(3L, 3L))
  p1 <- c(55, 20, 5) / 80
  expect_equal(got$shannon[1], -sum(p1 * log(p1)))
  expect_equal(got$simpson[1], sum(p1^2))
  ref <- ref_ind(c("P1", "P1", "P1", "P2", "P2", "P2"), rep(c("A", "B", "C"), 2),
                 c(55, 20, 5, 7.5, 50, 2.5))
  expect_equal(got$es, ref$es)
  expect_equal(got$shannon, ref$shannon)
  expect_equal(got$simpson, ref$simpson)
  # ES(50) by hand for P1 (real-valued Hurlbert via lgamma)
  es1 <- sum(sapply(c(55, 20, 5), function(ni)
    if (80 - ni >= 50) 1 - exp(lgamma(80 - ni + 1) + lgamma(80 - 50 + 1) -
                               lgamma(80 - ni - 50 + 1) - lgamma(80 + 1)) else 1))
  expect_equal(got$es[1], es1)
  # cells with records (W has none) and their summed share
  expect_equal(got$cells, c(2L, 2L))
  expect_equal(got$area, c(1.5, 1.25))
})

test_that("regression: shares of 1 give the unweighted pooled calc_indicators()", {
  skip_if_not_installed("DBI"); skip_if_not_installed("duckdb"); skip_if_not_installed("gsl")
  skip_if(!h3_ext_ok(), "duckdb h3 community extension unavailable")
  fx <- make_place_fixture(); con <- fx$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  m   <- memb(fx$cell, "P3", c("X", "Y", "Z"), 1)
  got <- obis_place_indicators(con, m, decades = FALSE, eov = FALSE)
  occ <- fx$occ[fx$occ$name %in% c("X", "Y", "Z"), ]
  ref <- ref_ind("P3", occ$species, occ$records)
  expect_equal(got$n, ref$n)
  expect_equal(got$sp, ref$sp)
  expect_equal(got$shannon, ref$shannon)
  expect_equal(got$simpson, ref$simpson)
  expect_equal(got$es, ref$es)
  expect_equal(got$n, 150)
  expect_equal(got$area, 3)
})

test_that("a cell in two places counts in both with its own share", {
  skip_if_not_installed("DBI"); skip_if_not_installed("duckdb")
  skip_if(!h3_ext_ok(), "duckdb h3 community extension unavailable")
  fx <- make_place_fixture(); con <- fx$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  # Y alone in P1 at 0.5 and in P2 at 0.25: 40 records -> 20 and 10
  m   <- rbind(memb(fx$cell, "P1", "Y", 0.5), memb(fx$cell, "P2", "Y", 0.25))
  got <- obis_place_indicators(con, m, decades = FALSE, eov = FALSE)
  expect_equal(got$n, c(20, 10))
  expect_equal(got$sp, c(2L, 2L))
  # the same proportions (A 3/4, C 1/4) in both places
  expect_equal(got$simpson, rep(0.75^2 + 0.25^2, 2))
  expect_equal(got$area, c(0.5, 0.25))
})

test_that("decade rows sum back to all years for n; eov layers follow the eov table", {
  skip_if_not_installed("DBI"); skip_if_not_installed("duckdb")
  skip_if(!h3_ext_ok(), "duckdb h3 community extension unavailable")
  fx <- make_place_fixture(); con <- fx$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  m <- rbind(memb(fx$cell, "P1", c("X", "Y"), c(1, 0.5)),
             memb(fx$cell, "P2", c("Y", "Z"), c(0.25, 1)))
  got <- obis_place_indicators(con, m)
  a   <- got[got$layer == "all", ]
  # P1: 2010s A 55 + C 5 = 60, 1970s B 20; P2: 2010s 10, 1980s 50
  p1 <- a[a$place_id == "P1", ]
  expect_equal(p1$decade, c(NA, 1970L, 2010L))
  expect_equal(p1$n, c(80, 20, 60))
  p2 <- a[a$place_id == "P2", ]
  expect_equal(p2$decade, c(NA, 1980L, 2010L))
  expect_equal(p2$n, c(60, 50, 10))
  for (p in c("P1", "P2")) {
    x <- a[a$place_id == p, ]
    expect_equal(sum(x$n[!is.na(x$decade)]), x$n[is.na(x$decade)])
  }
  # cells and area per decade: P2's 2010s are Y only (0.25)
  expect_equal(p2$cells, c(2L, 1L, 1L))
  expect_equal(p2$area, c(1.25, 1, 0.25))

  # eov: fish = A + C, seabirds = B
  e <- got[got$layer == "eov" & is.na(got$decade), ]
  expect_equal(e$place_id, c("P1", "P1", "P2", "P2"))
  expect_equal(e$key, c("fish", "seabirds", "fish", "seabirds"))
  expect_equal(e$n, c(60, 20, 10, 50))
  expect_equal(e$sp, c(2L, 1L, 2L, 1L))
  ed <- got[got$layer == "eov" & !is.na(got$decade), ]
  for (k in c("fish", "seabirds")) for (p in c("P1", "P2"))
    expect_equal(sum(ed$n[ed$key == k & ed$place_id == p]),
                 e$n[e$key == k & e$place_id == p])

  # only the requested decades, none outside them; eov = FALSE drops the layer
  got2 <- obis_place_indicators(con, m, decades = 2010L, eov = FALSE)
  expect_setequal(unique(got2$layer), "all")
  expect_equal(sort(unique(stats::na.omit(got2$decade))), 2010L)
})

test_that("es is NA where the weighted n is below esn", {
  skip_if_not_installed("DBI"); skip_if_not_installed("duckdb")
  skip_if(!h3_ext_ok(), "duckdb h3 community extension unavailable")
  fx <- make_place_fixture(); con <- fx$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  # X has 60 records: es defined at share 1, NA at share 0.8 (n 48 < 50)
  m   <- rbind(memb(fx$cell, "full", "X", 1), memb(fx$cell, "part", "X", 0.8))
  got <- obis_place_indicators(con, m, decades = FALSE, eov = FALSE)
  expect_equal(got$place_id, c("full", "part"))
  expect_equal(got$n, c(60, 48))
  expect_false(is.na(got$es[1]))
  expect_true(is.na(got$es[2]))
  # and es is defined again at a lower esn
  expect_false(is.na(obis_place_indicators(con, m[2, ], esn = 10, decades = FALSE,
                                           eov = FALSE)$es))
})

test_that("membership at a coarser res rolls the store's tier up; a res mismatch stops", {
  skip_if_not_installed("DBI"); skip_if_not_installed("duckdb")
  skip_if(!h3_ext_ok(), "duckdb h3 community extension unavailable")
  fx <- make_place_fixture(); con <- fx$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  x6  <- DBI::dbGetQuery(con, sprintf(
    "SELECT h3_h3_to_string(h3_cell_to_parent(h3_string_to_h3('%s'), 6)) AS h", fx$cell["X"]))$h
  got <- obis_place_indicators(con, data.frame(place_id = "P", h3 = x6, share = 0.5),
                               res = 6L, decades = FALSE, eov = FALSE)
  expect_equal(got$n, 30)
  expect_error(obis_place_indicators(con, data.frame(place_id = "P", h3 = x6, share = 1),
                                     res = 7L, decades = FALSE, eov = FALSE),
               "not res 7")
})

test_that("gazetteer membership files (real noaa_aoa_socal) resolve and read", {
  skip_if_not_installed("DBI"); skip_if_not_installed("duckdb"); skip_if_not_installed("jsonlite")
  skip_if(!h3_ext_ok(), "duckdb h3 community extension unavailable")
  coll <- test_path("fixtures", "places", "noaa_aoa_socal")

  mb <- obis_place_membership(coll, res = 7L)
  expect_length(mb$files, 2L)
  expect_true(all(file.exists(mb$files)))
  expect_true(all(grepl("/h3/res=7/p=[0-9a-f]+/membership.parquet$", mb$files)))
  expect_equal(mb$info$slug, "noaa_aoa_socal")
  # the same from the h3/ dir or the json itself
  expect_equal(obis_place_membership(file.path(coll, "h3"))$files, mb$files)
  expect_equal(obis_place_membership(file.path(coll, "h3", "membership.json"))$files, mb$files)
  expect_length(obis_place_membership(coll, res = 5L)$files, 1L)
  expect_error(obis_place_membership(coll, res = 0L), "no res 0")

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "LOAD h3;")
  # 100 records on one member cell of AOA:N1-A (share 0.4581942, float32)
  sh <- DBI::dbGetQuery(con, sprintf(
    "SELECT place_id, share::DOUBLE AS share FROM read_parquet([%s], hive_partitioning = false)
     WHERE h3 = '872912751ffffff'", paste0("'", mb$files, "'", collapse = ", ")))
  DBI::dbExecute(con, "
    CREATE TABLE occ_h3 AS
    SELECT 7::UTINYINT AS res, CAST(h3_string_to_h3('872912751ffffff') AS BIGINT) AS cell_id,
           1::BIGINT AS aphiaid, 'A' AS species, 2015::SMALLINT AS date_year, 100::BIGINT AS records")
  for (m in list(mb, mb$files, coll)) {
    got <- obis_place_indicators(con, m, decades = FALSE, eov = FALSE)
    expect_setequal(got$place_id, sh$place_id)
    expect_equal(got$n[match(sh$place_id, got$place_id)], 100 * sh$share)
    expect_equal(got$cells, rep(1L, nrow(got)))
  }
})
