# obis_place_indicators_exact(): exact point-in-polygon indicators per place.
# the parity tests pin it to calc_indicators() on the points inside the
# polygon, computed independently in R; the other tests give each rule its own
# small synthetic fixture. needs the duckdb spatial extension (skipped without).

skip_exact <- function() {
  skip_if_not_installed("DBI"); skip_if_not_installed("duckdb")
  skip_if_not_installed("sf"); skip_if_not_installed("gsl")
  skip_if(!spatial_ext_ok(), "duckdb spatial extension unavailable")
}

# BOX: lon -60..-40, lat -50..-30 ; ELL: an L (concave) at lon -30..-10, lat -50..-30
PE_BOX <- pe_poly(matrix(c(-60, -50, -40, -50, -40, -30, -60, -30), ncol = 2, byrow = TRUE))
PE_ELL <- pe_poly(matrix(c(-30, -50, -10, -50, -10, -40, -20, -40, -20, -30, -30, -30),
                         ncol = 2, byrow = TRUE))
in_box <- function(d) d$decimalLongitude >= -60 & d$decimalLongitude <= -40 &
  d$decimalLatitude >= -50 & d$decimalLatitude <= -30
# the L is two closed boxes: lat -50..-40 across lon -30..-10, and lat -40..-30 over lon -30..-20
in_ell <- function(d) {
  x <- d$decimalLongitude; y <- d$decimalLatitude
  (x >= -30 & x <= -10 & y >= -50 & y <= -40) | (x >= -30 & x <= -20 & y >= -40 & y <= -30)
}

# shipped occ_SAtlantic with a synthetic aphiaid (the species' rank) ----
pe_occ <- function() {
  d <- as.data.frame(occ_SAtlantic)
  d$aphiaid <- as.numeric(as.integer(factor(d$species)))
  d
}

# a synthetic, deterministic EOV membership: each of the 7 EOVs gets the taxa with
# aphiaid %% 7 == k (distinct, non-empty), seabirds and fish also take a second, overlapping subset
pe_eov_taxa <- function(aphiaid) {
  ids <- sort(unique(aphiaid))
  nms <- names(OBIS_EOV)
  out <- lapply(seq_along(nms), function(k) ids[ids %% 7 == k - 1])
  names(out) <- nms
  out$seabirds <- union(out$seabirds, ids[ids %% 13 == 0])
  out$fish     <- union(out$fish, ids[ids %% 11 == 0])
  out
}
pe_eov <- function(aphiaid) {
  tx <- pe_eov_taxa(aphiaid)
  data.frame(eov = rep(names(tx), lengths(tx)), taxonID = unlist(tx, use.names = FALSE),
             stringsAsFactors = FALSE)
}

# calc_indicators() on a subset of points, as one cell
ref_ind <- function(d, esn = 50) {
  stopifnot(nrow(d) > 0)
  d$cell <- "P"
  as.data.frame(calc_indicators(d, esn = esn))
}

# one row of the exact result against the reference: n and sp exact, the rest to tolerance
expect_ind <- function(row, ref) {
  expect_equal(nrow(row), 1L)
  expect_equal(row$n, ref$n)
  expect_equal(row$sp, ref$sp)
  expect_equal(row$shannon, ref$shannon, tolerance = 1e-9)
  expect_equal(row$simpson, ref$simpson, tolerance = 1e-9)
  expect_equal(row$hill_1,  ref$hill_1,  tolerance = 1e-9)
  expect_equal(row$hill_2,  ref$hill_2,  tolerance = 1e-9)
  expect_equal(row$bp,      ref$maxp,    tolerance = 1e-9)
  expect_equal(row$es,      ref$es,      tolerance = 1e-3)  # lgamma vs gsl::lngamma
}

pe_row <- function(res, place, eov = "all", decade = NA, year = NULL) {
  if (is.null(year)) {
    x <- res$indicators
    x[x$place_id == place & x$eov == eov &
        (if (is.na(decade)) is.na(x$decade) else x$decade %in% decade), ]
  } else {
    x <- res$years
    x[x$place_id == place & x$eov == eov & x$year %in% year, ]
  }
}

# one shared run: BOX + ELL (disjoint), every EOV, decades and years
pe_cache <- new.env()
pe_main <- function() {
  if (is.null(pe_cache$res)) {
    occ <- pe_occ()
    pe_cache$occ <- occ
    pe_cache$res <- obis_place_indicators_exact(
      occ, pe_sf(BOX = PE_BOX, ELL = PE_ELL), eov = pe_eov(occ$aphiaid))
  }
  list(occ = pe_cache$occ, res = pe_cache$res)
}

test_that("all taxa, all years: a box and an L-shaped polygon equal calc_indicators() on the points inside", {
  skip_exact()
  fx <- pe_main(); occ <- fx$occ; res <- fx$res
  expect_equal(names(res), c("indicators", "years", "diagnostics"))
  expect_equal(names(res$indicators),
               c("place_id", "eov", "decade", "n", "sp", "shannon", "simpson", "es",
                 "hill_1", "hill_2", "bp", "density"))
  expect_equal(names(res$years),
               c("place_id", "eov", "year", "n", "sp", "shannon", "simpson", "es",
                 "hill_1", "hill_2", "bp", "density"))
  for (p in c("BOX", "ELL")) {
    inside <- if (p == "BOX") occ[in_box(occ), ] else occ[in_ell(occ), ]
    ref <- ref_ind(inside)
    row <- pe_row(res, p)
    expect_ind(row, ref)
  }
  expect_gt(pe_row(res, "BOX")$n, 1e4)
  expect_gt(pe_row(res, "ELL")$n, 1e3)
  expect_true(pe_row(res, "BOX")$sp > 100)
})

test_that("per decade and per year equal calc_indicators() on the subset", {
  skip_exact()
  fx <- pe_main(); occ <- fx$occ; res <- fx$res
  inside <- occ[in_box(occ), ]
  dec <- floor(inside$date_year / 10) * 10
  for (d in c(1970, 1990, 2000)) {
    expect_ind(pe_row(res, "BOX", decade = d), ref_ind(inside[!is.na(dec) & dec == d, ]))
  }
  for (y in c(1995, 2003, 2008)) {
    expect_ind(pe_row(res, "BOX", year = y), ref_ind(inside[!is.na(inside$date_year) & inside$date_year == y, ]))
  }
  ell <- occ[in_ell(occ), ]
  dec <- floor(ell$date_year / 10) * 10
  expect_ind(pe_row(res, "ELL", decade = 2000), ref_ind(ell[!is.na(dec) & dec == 2000, ]))
  expect_ind(pe_row(res, "ELL", year = 2005), ref_ind(ell[!is.na(ell$date_year) & ell$date_year == 2005, ]))

  # the decade rows are exactly the requested decades with records; years are all years with records
  x <- res$indicators[res$indicators$place_id == "BOX" & res$indicators$eov == "all", ]
  have <- sort(unique(dec <- floor(inside$date_year / 10) * 10))
  expect_equal(sort(stats::na.omit(x$decade)), as.integer(intersect(seq(1960, 2020, 10), have)))
  yy <- res$years[res$years$place_id == "BOX" & res$years$eov == "all", ]
  expect_equal(yy$year, as.integer(sort(unique(stats::na.omit(inside$date_year)))))
  # records with a year sum to the year rows; decade rows to at most all years
  expect_equal(sum(yy$n), sum(inside$records[!is.na(inside$date_year)]))
  expect_lte(sum(x$n[!is.na(x$decade)]), x$n[is.na(x$decade)])
})

for (k in names(OBIS_EOV)) local({
  k <- k
  test_that(paste0("EOV ", k, ": the eov row equals calc_indicators() on the inside points of its taxa"), {
    skip_exact()
    fx <- pe_main(); occ <- fx$occ; res <- fx$res
    taxa <- pe_eov_taxa(occ$aphiaid)[[k]]
    expect_gt(length(taxa), 0)
    for (p in c("BOX", "ELL")) {
      inside <- if (p == "BOX") occ[in_box(occ), ] else occ[in_ell(occ), ]
      inside <- inside[inside$aphiaid %in% taxa, ]
      row <- pe_row(res, p, eov = k)
      expect_ind(row, ref_ind(inside))
      # and for a decade
      dec <- floor(inside$date_year / 10) * 10
      expect_ind(pe_row(res, p, eov = k, decade = 2000), ref_ind(inside[!is.na(dec) & dec == 2000, ]))
    }
    # a year
    inside <- occ[in_box(occ) & occ$aphiaid %in% taxa & !is.na(occ$date_year) & occ$date_year == 2005, ]
    expect_ind(pe_row(res, "BOX", eov = k, year = 2005), ref_ind(inside))
  })
})

test_that("an eov row never exceeds the all-taxa row, and eov names come from the membership", {
  skip_exact()
  res <- pe_main()$res
  expect_setequal(unique(res$indicators$eov), c("all", names(OBIS_EOV)))
  a <- pe_row(res, "BOX")
  for (k in names(OBIS_EOV)) {
    e <- pe_row(res, "BOX", eov = k)
    expect_lte(e$n, a$n)
    expect_lte(e$sp, a$sp)
  }
})

test_that("totals: in + out == total for non-overlapping places, with no warning", {
  skip_exact()
  fx <- pe_main(); occ <- fx$occ; dg <- fx$res$diagnostics
  expect_equal(dg$records_total, sum(occ$records))
  expect_equal(dg$records_in, sum(occ$records[in_box(occ) | in_ell(occ)]))
  expect_equal(dg$records_in + dg$records_out, dg$records_total)
  expect_equal(dg$records_in_unique, dg$records_in)
  expect_equal(dg$overlaps$n, 0)
  expect_length(dg$overlaps$place_ids, 0)
  expect_equal(dg$n_places, 2)
  expect_equal(dg$n_places_with_records, 2)
  # the all-taxa, all-years rows hold exactly the records inside
  expect_equal(pe_row(fx$res, "BOX")$n, sum(occ$records[in_box(occ)]))
  expect_gt(dg$records_out, 0)
})

test_that("overlapping places are counted, named and warned about", {
  skip_exact()
  occ <- pe_occ()
  a <- PE_BOX                                                    # lon -60..-40, lat -50..-30
  b <- pe_poly(matrix(c(-50, -40, -30, -40, -30, -20, -50, -20), ncol = 2, byrow = TRUE))
  # overlap region: lon -50..-40, lat -40..-30
  expect_warning(
    res <- obis_place_indicators_exact(occ, pe_sf(A = a, B = b), decades = FALSE, years = FALSE),
    "more than one place")
  in_a <- in_box(occ)
  in_b <- occ$decimalLongitude >= -50 & occ$decimalLongitude <= -30 &
    occ$decimalLatitude >= -40 & occ$decimalLatitude <= -20
  both <- in_a & in_b
  dg <- res$diagnostics
  expect_gt(dg$overlaps$n, 0)
  expect_equal(dg$overlaps$n, nrow(unique(occ[both, c("decimalLongitude", "decimalLatitude")])))
  expect_equal(dg$overlaps$place_ids, c("A", "B"))
  expect_equal(dg$overlaps$records, sum(occ$records[both]))
  # a location in both places is counted in each; the unique total is not double counted
  expect_equal(dg$records_in, sum(occ$records[in_a]) + sum(occ$records[in_b]))
  expect_equal(dg$records_in_unique, sum(occ$records[in_a | in_b]))
  expect_equal(dg$records_in_unique + dg$records_out, dg$records_total)
  expect_equal(pe_row(res, "A")$n, sum(occ$records[in_a]))
  expect_equal(pe_row(res, "B")$n, sum(occ$records[in_b]))
  expect_equal(nrow(res$years), 0L)
  expect_equal(names(res$years)[3], "year")
})

test_that("antimeridian: a place split at +/-180 matches points on both sides", {
  skip_exact()
  d <- data.frame(
    decimalLongitude = c(179.5, 179.5, -179.5, 170, -170, 179.9999, -180),
    decimalLatitude  = c(10, 10, 12, 10, 10, 19, 5),
    species          = c("A", "B", "A", "C", "D", "E", "F"),
    date_year        = 2000L,
    records          = c(2, 3, 4, 100, 100, 1, 1))
  east <- matrix(c(178, 0, 180, 0, 180, 20, 178, 20), ncol = 2, byrow = TRUE)
  west <- matrix(c(-180, 0, -178, 0, -178, 20, -180, 20), ncol = 2, byrow = TRUE)
  mp <- sf::st_multipolygon(list(list(rbind(east, east[1, ])), list(rbind(west, west[1, ]))))
  res <- obis_place_indicators_exact(d, pe_sf(AM = mp), decades = FALSE)
  r <- pe_row(res, "AM")
  # inside: 179.5 x2 (A 2, B 3), -179.5 (A 4), 179.9999 (E 1); (-180, 5) is on the west edge: F 1
  expect_equal(r$n, 2 + 3 + 4 + 1 + 1)
  expect_equal(r$sp, 4L)           # A, B, E, F
  expect_equal(res$diagnostics$records_out, 200)
  expect_equal(res$diagnostics$records_total, 211)
  # the same place from a GeoParquet file of WKB, stored split as the gazetteer does
  f <- tempfile(fileext = ".parquet")
  on.exit(unlink(f), add = TRUE)
  pe_write_places(f, pe_sf(AM = mp), geometry_type = "blob")
  res2 <- obis_place_indicators_exact(d, f, decades = FALSE)
  expect_equal(res2$indicators, res$indicators)
})

test_that("places from a GeoParquet (WKB blob or native geometry) equal places from sf", {
  skip_exact()
  occ <- pe_occ()
  pl <- pe_sf(BOX = PE_BOX, ELL = PE_ELL)
  ref <- obis_place_indicators_exact(occ, pl, decades = FALSE, years = FALSE)
  for (ty in c("blob", "geometry")) {
    f <- tempfile(fileext = ".parquet")
    pe_write_places(f, pl, ty)
    got <- obis_place_indicators_exact(occ, f, decades = FALSE, years = FALSE)
    expect_equal(got$indicators, ref$indicators, info = ty)
    unlink(f)
  }
})

test_that("grid clipping does not change results: grid_deg 1, 0.7 and 10 agree", {
  skip_exact()
  occ <- pe_occ()
  eov <- pe_eov(occ$aphiaid)
  pl  <- pe_sf(BOX = PE_BOX, ELL = PE_ELL)
  r1  <- obis_place_indicators_exact(occ, pl, eov = eov, grid_deg = 1, decades = c(1990, 2000), years = 2000)
  r07 <- obis_place_indicators_exact(occ, pl, eov = eov, grid_deg = 0.7, decades = c(1990, 2000), years = 2000)
  r10 <- obis_place_indicators_exact(occ, pl, eov = eov, grid_deg = 10, decades = c(1990, 2000), years = 2000)
  expect_gt(r1$diagnostics$n_pieces, r10$diagnostics$n_pieces)
  expect_gt(r07$diagnostics$n_pieces, r1$diagnostics$n_pieces)
  expect_equal(r1$indicators, r10$indicators)
  expect_equal(r1$indicators, r07$indicators)
  expect_equal(r1$years, r10$years)
  expect_equal(r1$diagnostics$records_in, r10$diagnostics$records_in)
  expect_equal(sort(unique(r1$years$year)), 2000L)
  expect_setequal(stats::na.omit(unique(r1$indicators$decade)), c(1990L, 2000L))
})

test_that("a point on a grid line inside a place is counted once", {
  skip_exact()
  # (2, 2) lies on the corner of four 1-degree pieces of the same place
  d <- data.frame(decimalLongitude = c(2, 2.5), decimalLatitude = c(2, 2.5),
                  species = c("A", "B"), records = c(5, 7))
  r <- obis_place_indicators_exact(d, pe_sf(P = pe_poly(matrix(c(0, 0, 4, 0, 4, 4, 0, 4), ncol = 2, byrow = TRUE))),
                                   decades = FALSE, years = FALSE)
  expect_equal(pe_row(r, "P")$n, 12)
  expect_equal(r$diagnostics$overlaps$n, 0)
})

test_that("density is n / area_km2: given area exactly, else the geodesic area of the polygon", {
  skip_exact()
  occ <- pe_occ()
  pl  <- pe_sf(BOX = PE_BOX, ELL = PE_ELL)
  pl$area_km2 <- c(1000, 250)
  r <- obis_place_indicators_exact(occ, pl, eov = pe_eov(occ$aphiaid), decades = 2000, years = 2005)
  ar <- c(BOX = 1000, ELL = 250)
  expect_equal(r$indicators$density, r$indicators$n / unname(ar[r$indicators$place_id]))
  expect_equal(r$years$density, r$years$n / unname(ar[r$years$place_id]))
  expect_equal(pe_row(r, "BOX")$density, pe_row(r, "BOX")$n / 1000)

  # absent: computed. a lon/lat box has the spherical area R^2 * dlon * (sin(lat2) - sin(lat1))
  r2 <- obis_place_indicators_exact(occ, pe_sf(BOX = PE_BOX), decades = FALSE, years = FALSE)
  a_box <- 6371.0088^2 * (20 * pi / 180) * (sin(-30 * pi / 180) - sin(-50 * pi / 180))
  b <- pe_row(r2, "BOX")
  expect_gt(b$density, 0)
  expect_equal(b$n / b$density, a_box, tolerance = 0.01)
  # a parquet's area_km2 column is used as well
  f <- tempfile(fileext = ".parquet")
  on.exit(unlink(f), add = TRUE)
  pe_write_places(f, pe_sf(BOX = PE_BOX), area = 500)
  r3 <- obis_place_indicators_exact(occ, f, decades = FALSE, years = FALSE)
  expect_equal(pe_row(r3, "BOX")$density, pe_row(r3, "BOX")$n / 500)
})

test_that("filters: NA species / coordinates are dropped from a data frame; records are summed", {
  skip_exact()
  d <- data.frame(
    decimalLongitude = c(1, 1, 2, NA, 3, 50),
    decimalLatitude  = c(1, 1, 2, 3, NA, 50),
    species          = c("A", "A", NA, "B", "C", "F"),
    date_year        = c(2000L, 2000L, 2000L, 2000L, 2000L, NA),
    records          = c(2, 3, 100, 100, 100, 7))
  box <- pe_sf(P = pe_poly(matrix(c(0, 0, 10, 0, 10, 10, 0, 10), ncol = 2, byrow = TRUE)))
  r <- obis_place_indicators_exact(d, box, decades = FALSE)
  expect_equal(pe_row(r, "P")$n, 5)
  expect_equal(pe_row(r, "P")$sp, 1L)
  expect_equal(r$diagnostics$records_total, 5 + 7)
  expect_equal(r$diagnostics$records_out, 7)
  # without a records column, each row counts once
  r2 <- obis_place_indicators_exact(d[, setdiff(names(d), "records")], box, decades = FALSE)
  expect_equal(pe_row(r2, "P")$n, 2)
  # the F record has no year: it is outside the box anyway; a yearless record inside counts
  # in the all-years row but in no decade or year row
  d2 <- rbind(d, data.frame(decimalLongitude = 5, decimalLatitude = 5, species = "G",
                            date_year = NA_integer_, records = 11))
  r3 <- obis_place_indicators_exact(d2, box, decades = 2000)
  expect_equal(pe_row(r3, "P")$n, 16)
  expect_equal(pe_row(r3, "P", decade = 2000)$n, 5)
  expect_equal(sum(r3$years$n), 5)
})

# OBIS-like parquet fixtures, flat and nested (`interpreted` struct) ----
pe_write_obis <- function(dir, nested) {
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "
    CREATE TABLE o AS SELECT * FROM (VALUES
      (1.0::DOUBLE, 1.0::DOUBLE, 'A', 2000, 11, false, false),
      (1.0, 1.0, 'A', 2000, 11, false, false),
      (2.0, 2.0, 'B', 2001, 12, false, true),
      (3.0, 3.0, 'C', 2001, 13, true,  false),
      (4.0, 4.0, 'D', 2002, 14, NULL,  NULL),
      (5.0, 5.0, NULL, 2002, 15, false, false),
      (6.0, NULL, 'E', 2002, 16, false, false),
      (50.0, 50.0, 'F', 2003, 17, false, false)
    ) t(lon, lat, species, date_year, aphiaid, dropped, absence);")
  f <- file.path(dir, if (nested) "nested.parquet" else "flat.parquet")
  sel <- if (nested)
    "struct_pack(decimalLongitude := lon, decimalLatitude := lat, species := species,
                 date_year := date_year, aphiaid := aphiaid) AS interpreted, dropped, absence"
  else
    "lon AS decimalLongitude, lat AS decimalLatitude, species, date_year, aphiaid, dropped, absence"
  DBI::dbExecute(con, sprintf("COPY (SELECT %s FROM o) TO '%s' (FORMAT PARQUET)", sel, f))
  f
}

test_that("filters on parquet: dropped / absence TRUE are excluded, flat and nested layouts, path and glob", {
  skip_exact()
  dir <- tempfile("obis"); dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  box <- pe_sf(P = pe_poly(matrix(c(0, 0, 10, 0, 10, 10, 0, 10), ncol = 2, byrow = TRUE)))
  for (nested in c(FALSE, TRUE)) {
    sub <- file.path(dir, if (nested) "n" else "f"); dir.create(sub)
    f <- pe_write_obis(sub, nested)
    # kept: A x2 (11), D (14, dropped/absence NULL); out: F; dropped: B (absence), C (dropped),
    # NULL species, NULL latitude
    for (src in list(f, file.path(sub, "*.parquet"))) {
      r <- obis_place_indicators_exact(src, box, eov = data.frame(eov = c("x", "y"), taxonID = c(11, 14)),
                                       decades = 2000)
      lab <- paste(if (nested) "nested" else "flat", src)
      expect_equal(pe_row(r, "P")$n, 3, info = lab)
      expect_equal(pe_row(r, "P")$sp, 2L, info = lab)
      expect_equal(r$diagnostics$records_total, 4, info = lab)
      expect_equal(r$diagnostics$records_out, 1, info = lab)
      expect_equal(pe_row(r, "P", decade = 2000)$n, 3, info = lab)
      expect_equal(pe_row(r, "P", eov = "x")$n, 2, info = lab)
      expect_equal(pe_row(r, "P", eov = "y")$n, 1, info = lab)
      expect_equal(r$years$year[r$years$eov == "all"], c(2000L, 2002L), info = lab)
    }
  }
})

test_that("eov from a store connection's eov table, and input validation", {
  skip_exact()
  occ <- pe_occ()
  pl  <- pe_sf(BOX = PE_BOX)
  m   <- pe_eov(occ$aphiaid)
  m   <- m[m$eov %in% c("fish", "seabirds"), ]
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbWriteTable(con, "eov", m)
  r1 <- obis_place_indicators_exact(occ, pl, eov = con, decades = FALSE, years = FALSE)
  r2 <- obis_place_indicators_exact(occ, pl, eov = m, decades = FALSE, years = FALSE)
  expect_equal(r1$indicators, r2$indicators)
  expect_setequal(r1$indicators$eov, c("all", "fish", "seabirds"))
  expect_equal(r1$indicators$eov[1], "all")

  expect_error(obis_place_indicators_exact(occ, rbind(pl, pl)), "unique")
  expect_error(obis_place_indicators_exact(occ, sf::st_sf(id = "x", geometry = sf::st_geometry(pl))), "place_id")
  expect_error(obis_place_indicators_exact(occ[, setdiff(names(occ), "species")], pl), "species")
  expect_error(obis_place_indicators_exact(occ[, setdiff(names(occ), "aphiaid")], pl, eov = m), "aphiaid")
  expect_error(obis_place_indicators_exact(occ, pl, grid_deg = 0))
  expect_error(obis_place_indicators_exact(occ, pl, eov = data.frame(a = 1)), "eov")
  # no data in the places: empty tables, still the documented columns
  far <- pe_sf(FAR = pe_poly(matrix(c(100, 60, 101, 60, 101, 61, 100, 61), ncol = 2, byrow = TRUE)))
  r3 <- obis_place_indicators_exact(occ, far)
  expect_equal(nrow(r3$indicators), 0L)
  expect_equal(nrow(r3$years), 0L)
  expect_equal(r3$diagnostics$records_in, 0)
  expect_equal(r3$diagnostics$records_out, r3$diagnostics$records_total)
})

test_that("a user connection is used and left clean", {
  skip_exact()
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  d <- data.frame(decimalLongitude = 1, decimalLatitude = 1, species = "A", records = 3)
  r <- obis_place_indicators_exact(d, pe_sf(P = pe_poly(matrix(c(0, 0, 2, 0, 2, 2, 0, 2), ncol = 2, byrow = TRUE))),
                                   con = con, decades = FALSE, years = FALSE)
  expect_equal(r$indicators$n, 3)
  expect_equal(DBI::dbListTables(con), character(0))
  expect_true(DBI::dbIsValid(con))
})

test_that("obis_place_exact_write() writes values-only parquet and meta.json", {
  skip_exact(); skip_if_not_installed("jsonlite")
  occ <- pe_occ()
  res <- obis_place_indicators_exact(occ, pe_sf(BOX = PE_BOX, ELL = PE_ELL),
                                     eov = pe_eov(occ$aphiaid), decades = c(1990, 2000), years = c(2000, 2001))
  dir <- tempfile("release"); on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  files <- obis_place_exact_write(res, dir, "test_coll")
  d <- file.path(dir, "place_exact", "coll=test_coll")
  expect_true(all(file.exists(file.path(d, c("indicators.parquet", "years.parquet", "meta.json")))))
  expect_equal(basename(files), c("indicators.parquet", "years.parquet", "meta.json"))

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  ind <- DBI::dbGetQuery(con, sprintf("SELECT * FROM read_parquet('%s', hive_partitioning = false)", file.path(d, "indicators.parquet")))
  yr  <- DBI::dbGetQuery(con, sprintf("SELECT * FROM read_parquet('%s', hive_partitioning = false)", file.path(d, "years.parquet")))
  expect_equal(names(ind), c("place_id", "eov", "decade", "n", "sp", "shannon", "simpson", "es",
                             "hill_1", "hill_2", "bp", "density"))
  expect_equal(names(yr), c("place_id", "eov", "year", "n", "sp", "shannon", "simpson", "es",
                            "hill_1", "hill_2", "bp", "density"))
  expect_false(any(grepl("geom", c(names(ind), names(yr)), ignore.case = TRUE)))
  expect_equal(nrow(ind), nrow(res$indicators))
  expect_equal(nrow(yr), nrow(res$years))
  expect_equal(ind$n, res$indicators$n)
  expect_equal(sort(unique(yr$year)), c(2000L, 2001L))
  # ZSTD
  comp <- DBI::dbGetQuery(con, sprintf("SELECT DISTINCT compression FROM parquet_metadata('%s')",
                                       file.path(d, "indicators.parquet")))$compression
  expect_equal(comp, "ZSTD")

  m <- jsonlite::read_json(file.path(d, "meta.json"))
  expect_equal(m$coll, "test_coll")
  expect_equal(m$n_places, 2)
  expect_equal(m$rows$indicators, nrow(ind))
  expect_equal(m$rows$years, nrow(yr))
  expect_equal(m$records_in, res$diagnostics$records_in)
  expect_equal(m$records_out, res$diagnostics$records_out)
  expect_equal(m$records_total, res$diagnostics$records_total)
  expect_equal(m$overlaps, 0)
  expect_match(m$created, "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$")
  expect_false(is.null(m$obisindicators_version))
  expect_error(obis_place_exact_write(res, dir, "bad/slug"))
})
