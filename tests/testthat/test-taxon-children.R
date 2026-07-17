# arbitrary-rank children resolution over the WoRMS `taxon` table, and the
# occ_h3 filter it drives. see R/taxon.R and obis_h3t_sql(aphiaid=).

test_that("aphiaid SQL is well-formed and injection-safe", {
  skip_if_not_installed("glue")

  s <- obis_h3t_sql("es", aphiaid = 137205)
  expect_match(s, "WITH RECURSIVE taxon_tree")
  expect_match(s, "aphiaid IN \\(SELECT taxonID FROM taxon_tree\\)")
  expect_match(s, "137205")
  # a non-integer id is rejected, not interpolated
  expect_error(obis_h3t_sql("es", aphiaid = "1; DROP TABLE taxon"), "AphiaID")
  expect_error(obis_taxon_subtree_sql("x"), "AphiaID")

  expect_match(obis_taxon_subtree_sql(137205), "SELECT DISTINCT taxonID")
  sp <- obis_spue_sql(1111, 1000)
  expect_match(sp, "num_tree")
  expect_match(sp, "den_tree")
  expect_match(sp, "AS value")
  expect_match(sp, "AS n")
})

test_that("obis_taxon_children() returns the full subtree with depths", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if(!h3_ext_ok(), "duckdb h3 community extension unavailable")

  fx <- make_taxon_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  ch <- obis_taxon_children(1000, con)
  # every descendant of Cetacea, across ranks; the bird subtree excluded
  expect_setequal(ch$taxonID,
    c(1000, 1100, 1101, 1110, 1111, 1112, 1120, 1121))
  expect_equal(ch$depth_level[ch$taxonID == 1000], 0)   # seed
  expect_equal(ch$depth_level[ch$taxonID == 1111], 3)   # Cetacea->Delphinidae->Tursiops->species
  expect_false(2001 %in% ch$taxonID)
  # a leaf species resolves to just itself
  expect_setequal(obis_taxon_children(1111, con)$taxonID, 1111)
})

test_that("obis_h3t_sql(aphiaid=) filters occ_h3 to the subtree", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if(!h3_ext_ok(), "duckdb h3 community extension unavailable")

  fx <- make_taxon_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  # bbox_placeholder = "" -> executed directly here (no h3t server to substitute it)
  sql <- obis_h3t_sql("n", aphiaid = 1000, res_placeholder = "7", bbox_placeholder = "")
  DBI::dbExecute(con, glue::glue("CREATE OR REPLACE TEMP TABLE _res AS {sql}"))
  got <- DBI::dbGetQuery(con,
    "SELECT h3_h3_to_string(cell_id) AS cell, value FROM _res")

  ref <- DBI::dbGetQuery(con, "
    SELECT h3_h3_to_string(cell_id) AS cell, SUM(records) AS value
    FROM occ_h3 WHERE aphiaid IN (1111, 1112, 1121) GROUP BY 1")

  m <- merge(got, ref, by = "cell", suffixes = c(".sql", ".ref"))
  expect_equal(nrow(m), nrow(ref))
  expect_equal(nrow(m), 3L)                       # the 3 cetacean cells (bird excluded)
  expect_equal(m$value.sql, m$value.ref)          # 60, 20, 40 records
})
