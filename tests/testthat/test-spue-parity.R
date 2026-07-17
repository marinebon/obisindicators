# the served SPUE effort-proxy SQL is a translation of calc_spue(); this pins
# the SQL to that R reference (mirrors the calc_indicators() <-> h3t contract).

test_that("obis_spue_sql() matches calc_spue()", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if(!h3_ext_ok(), "duckdb h3 community extension unavailable")

  fx <- make_taxon_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  # target = Tursiops truncatus (1111); effort = Cetacea (1000). resolve subtrees
  # the same way the served SQL does, then compute the R reference.
  num_ids <- obis_taxon_children(1111, con)$taxonID
  den_ids <- obis_taxon_children(1000, con)$taxonID

  occ <- DBI::dbGetQuery(con,
    "SELECT h3_h3_to_string(cell_id) AS cell, aphiaid, records FROM occ_h3")
  ref <- calc_spue(occ, num_ids, den_ids)

  sql <- obis_spue_sql(1111, 1000, res_placeholder = "7")
  DBI::dbExecute(con, glue::glue("CREATE OR REPLACE TEMP TABLE _spue AS {sql}"))
  got <- DBI::dbGetQuery(con,
    "SELECT h3_h3_to_string(cell_id) AS cell, value, n FROM _spue")

  m <- merge(ref, got, by = "cell")
  expect_equal(nrow(m), nrow(ref))
  expect_equal(nrow(m), 3L)                          # 3 cetacean (effort) cells
  # (10,-50): 30/60=0.5 ; (11,-51): 5/20=0.25 ; (12,-52): 0/40=0 (effort, no target)
  expect_equal(sort(m$value), c(0, 0.25, 0.5), tolerance = 1e-9)
  expect_equal(m$spue, m$value, tolerance = 1e-9)    # R ref also 0 (not NA) there
  expect_equal(as.numeric(m$n_den), as.numeric(m$n))  # n = effort record count
})
