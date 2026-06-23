# the h3t served/precomputed SQL indicators are a translation of
# calc_indicators(); this pins the SQL math to that R reference.

test_that("h3t SQL indicators match calc_indicators()", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("glue")
  skip_if_not_installed("gsl")  # calc_indicators() uses gsl::lngamma

  # the duckdb `h3` community extension must install/load (needs network once)
  h3_ok <- tryCatch({
    c0 <- DBI::dbConnect(duckdb::duckdb())
    on.exit(DBI::dbDisconnect(c0, shutdown = TRUE), add = TRUE)
    DBI::dbExecute(c0, "INSTALL h3 FROM community; LOAD h3;")
    TRUE
  }, error = function(e) FALSE)
  skip_if(!h3_ok, "duckdb h3 community extension unavailable")

  # small, reproducible subset of shipped South Atlantic occurrences
  set.seed(42)
  occ <- occ_SAtlantic[sample(nrow(occ_SAtlantic), 1e5), ]

  db <- tempfile(fileext = ".duckdb")
  build_obis_h3_duckdb(occ, db, overwrite = TRUE)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db, read_only = TRUE)
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(db) }, add = TRUE)
  DBI::dbExecute(con, "LOAD h3;")

  res <- 3L
  # join on the hex *string* — H3 BIGINT ids exceed R double precision (2^53)
  ref_long <- DBI::dbGetQuery(con, glue::glue(
    "SELECT h3_h3_to_string(CAST(h3_cell_to_parent(cell_id, {res}) AS BIGINT)) AS cell,
            species, SUM(records) AS records
     FROM occ_h3 WHERE res = 7 GROUP BY 1, 2"))
  ref <- calc_indicators(ref_long, esn = 50)

  sql <- DBI::dbGetQuery(con, glue::glue(
    "SELECT h3_h3_to_string(cell_id) AS cell, n, sp, shannon, simpson, es
     FROM idx_h3 WHERE res = {res}"))

  m <- merge(ref, sql, by = "cell", suffixes = c(".r", ".sql"))
  expect_gt(nrow(m), 0)
  expect_equal(nrow(m), nrow(sql))             # same cell set
  expect_identical(as.numeric(m$n.r),  as.numeric(m$n.sql))   # exact
  expect_identical(as.numeric(m$sp.r), as.numeric(m$sp.sql))  # exact
  expect_equal(m$shannon.r, m$shannon.sql, tolerance = 1e-8)
  expect_equal(m$simpson.r, m$simpson.sql, tolerance = 1e-8)
  expect_equal(m$es.r,      m$es.sql,      tolerance = 1e-3)   # lgamma float
})

test_that("obis_h3t_sql() projects exactly cell_id, value, n and substitutes {{res}}", {
  skip_if_not_installed("glue")

  for (ind in c("es", "sp", "shannon", "n")) {
    s <- obis_h3t_sql(ind)
    expect_match(s, "idx_h3")                       # default -> precomputed
    expect_match(s, "AS value")
    expect_true(grepl("{{res}}", s, fixed = TRUE))  # placeholder present
  }
  # filtered -> species-level store, with sanitized predicates
  s <- obis_h3t_sql("es", taxon = list(class = "Aves"), years = c(2000, 2020))
  expect_match(s, "occ_h3")
  expect_match(s, "lgamma")
  expect_match(s, '"class" = \'Aves\'')
  expect_match(s, "date_year >= 2000")
  expect_match(s, "date_year <= 2020")

  # injection attempt is single-quote-escaped, not interpolated raw
  s2 <- obis_h3t_sql("n", taxon = list(genus = "a' OR '1'='1"))
  expect_match(s2, "''", fixed = TRUE)
  expect_error(obis_h3t_sql("n", taxon = list(badrank = "x")), "unknown taxonomic rank")
})

test_that("obis_h3t_url() embeds a base64 ?q=", {
  skip_if_not_installed("base64enc")
  u <- obis_h3t_url(
    base_url = "h3tiles://h3t.example.org/h3t/{z}/{x}/{y}.h3t",
    indicator = "es", release = "v1")
  expect_match(u, "^h3tiles://", )
  expect_match(u, "\\?q=")
  expect_match(u, "&release=v1")
  # round-trips back to the SQL
  q <- sub(".*\\?q=([^&]+).*", "\\1", u)
  decoded <- rawToChar(base64enc::base64decode(utils::URLdecode(q)))
  expect_match(decoded, "idx_h3")
})
