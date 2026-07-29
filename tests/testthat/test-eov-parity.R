# EOVs as multi-seed AphiaID subtrees, and the precomputed idx_h3_eov layer.
# The indicator math here is a fifth copy of calc_indicators() (see the PARITY
# note on .h3t_idx_eov_sql), so it gets the same cell-for-cell pinning as
# idx_h3 / idx_h3_taxon in test-h3t-parity.R.

test_that("EOV seed definitions match the IOOS IdentifierList", {
  s <- obis_eov_seeds()
  expect_setequal(unique(s$eov),
    c("fish", "hardCorals", "mangroves", "marineMammals",
      "seabirds", "seagrasses", "seaTurtles"))
  # the published definition is 33 seed AphiaIDs across the 7 EOVs
  # (3 fish + 1 coral + 19 mangrove + 7 mammal + 1 bird + 1 seagrass + 1 turtle)
  expect_equal(nrow(s), 33)
  expect_type(s$aphiaid, "integer")

  expect_setequal(obis_eov_aphiaid("fish"), c(1829, 1517375, 152352))
  expect_equal(obis_eov_aphiaid("seaTurtles"), 987094)
  # seabirds is Aves = 1836; 1837 is Mammalia (an easy and costly mix-up)
  expect_equal(obis_eov_aphiaid("seabirds"), 1836)
  expect_false(1837 %in% obis_eov_aphiaid("seabirds"))
  # marineMammals carries the ACCEPTED Lutra felina id, not the synonym 343992
  expect_true(477316 %in% obis_eov_aphiaid("marineMammals"))
  expect_false(343992 %in% obis_eov_aphiaid("marineMammals"))
  expect_length(obis_eov_aphiaid("mangroves"), 19)

  expect_equal(nrow(obis_eov_seeds("seaTurtles")), 1)
})

test_that("unknown EOV names are rejected, not interpolated into SQL", {
  expect_error(obis_eov_sql("bogus"), "unknown EOV")
  expect_error(obis_eov_sql("seaTurtles' OR '1'='1"), "unknown EOV")
  expect_error(obis_eov_aphiaid(42), "must be one or more EOV names")
})

test_that("obis_eov_sql() routes between precomputed and live paths", {
  skip_if_not_installed("glue")

  # no year filter, one EOV -> the precomputed layer
  s <- obis_eov_sql("seaTurtles", indicator = "es")
  expect_match(s, "FROM idx_h3_eov")
  expect_match(s, "eov = 'seaTurtles'")
  expect_match(s, "es AS value")

  # a year range has no precomputed dimension -> live subtree over occ_h3
  y <- obis_eov_sql("fish", indicator = "n", years = c(2000, 2020))
  expect_match(y, "WITH RECURSIVE taxon_tree")
  expect_match(y, "aphiaid IN \\(SELECT taxonID FROM taxon_tree\\)")
  expect_match(y, "date_year")
  expect_false(grepl("idx_h3_eov", y))
  # all three fish seeds reach the query
  for (id in c(1829, 1517375, 152352)) expect_match(y, as.character(id))

  # several EOVs at once cannot use the one-EOV-per-row layer
  m <- obis_eov_sql(c("seaTurtles", "seabirds"))
  expect_false(grepl("idx_h3_eov", m))
  expect_match(m, "987094")
  expect_match(m, "1836")

  # ...and live can be forced for a store where the layer was never baked
  f <- obis_eov_sql("seaTurtles", live = TRUE)
  expect_false(grepl("idx_h3_eov", f))

  # every path projects exactly what the h3t service requires: cell_id, value, n
  # (the precomputed layers pass `n` through unaliased, the live paths alias it)
  for (q in list(s, y, m, f)) {
    expect_match(q, "cell_id")
    expect_match(q, "AS value")
    expect_match(q, "AS n|,\\s*n\\s+FROM")
  }
})

test_that("idx_h3_eov matches calc_indicators() restricted to the EOV subtree", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("glue")
  skip_if_not_installed("gsl")           # calc_indicators() uses gsl::lngamma
  skip_if(!h3_ext_ok(), "duckdb h3 community extension unavailable")

  fx <- make_eov_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  obis_eov_bake(con, eov = c("seaTurtles", "seabirds"), verbose = FALSE)

  # membership expanded the seed to its whole subtree, and stayed disjoint
  memb <- DBI::dbGetQuery(con, "SELECT eov, taxonID FROM eov ORDER BY eov, taxonID")
  expect_setequal(memb$taxonID[memb$eov == "seaTurtles"],
                  c(987094, 987095, 987096, 987097, 987098))
  expect_setequal(memb$taxonID[memb$eov == "seabirds"], c(1836, 1840))

  res <- 3L
  # R reference: the same records, restricted to the EOV, rolled up to res 3.
  # join on the hex *string* — H3 BIGINT ids exceed R double precision (2^53)
  ref_long <- DBI::dbGetQuery(con, glue::glue(
    "SELECT h3_h3_to_string(CAST(h3_cell_to_parent(o.cell_id, {res}) AS BIGINT)) AS cell,
            o.species, SUM(o.records) AS records
     FROM occ_h3 o JOIN eov e ON o.aphiaid = e.taxonID
     WHERE o.res = 7 AND e.eov = 'seaTurtles'
     GROUP BY 1, 2"))
  ref <- calc_indicators(ref_long, esn = 50)

  sql <- DBI::dbGetQuery(con, glue::glue(
    "SELECT h3_h3_to_string(cell_id) AS cell, n, sp, shannon, simpson, es
     FROM idx_h3_eov WHERE eov = 'seaTurtles' AND res = {res}"))

  m <- merge(ref, sql, by = "cell", suffixes = c(".r", ".sql"))
  expect_gt(nrow(m), 0)
  expect_equal(nrow(m), nrow(sql))                              # same cell set
  expect_identical(as.numeric(m$n.r),  as.numeric(m$n.sql))     # exact
  expect_identical(as.numeric(m$sp.r), as.numeric(m$sp.sql))    # exact
  expect_equal(m$shannon.r, m$shannon.sql, tolerance = 1e-8)
  expect_equal(m$simpson.r, m$simpson.sql, tolerance = 1e-8)
  expect_equal(m$es.r,      m$es.sql,      tolerance = 1e-3)    # lgamma float

  # the bird cell must not have leaked into the turtle EOV
  turtle_n <- sum(as.numeric(sql$n))
  expect_equal(turtle_n, 505)                                   # 120+80+45+200+60
  expect_false(300 %in% as.numeric(sql$n))
})

test_that("the precomputed EOV layer agrees with the live subtree path", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("glue")
  skip_if(!h3_ext_ok(), "duckdb h3 community extension unavailable")

  fx <- make_eov_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)
  obis_eov_bake(con, eov = "seaTurtles", verbose = FALSE)

  # the two routes are meant to be interchangeable; a user switching to a year
  # filter must not see the map jump
  run <- function(sql) DBI::dbGetQuery(con, paste0(
    "SELECT h3_h3_to_string(cell_id) AS cell, value, n FROM (",
    gsub("\\{\\{res\\}\\}", "3", sql), ")"))

  pre  <- run(obis_eov_sql("seaTurtles", indicator = "n"))
  live <- run(obis_eov_sql("seaTurtles", indicator = "n", live = TRUE))

  m <- merge(pre, live, by = "cell", suffixes = c(".pre", ".live"))
  expect_equal(nrow(m), nrow(pre))
  expect_equal(as.numeric(m$value.pre), as.numeric(m$value.live))
  expect_equal(as.numeric(m$n.pre),     as.numeric(m$n.live))
})

test_that("EOV seeds carry a rank and a plain-English definition", {
  s <- obis_eov_seeds()
  expect_true(all(c("desc", "rank") %in% names(s)))
  expect_false(anyNA(s$rank))
  expect_false(anyNA(s$desc))
  expect_true(all(nzchar(s$desc)))

  # the seeds deliberately span many ranks — that is the whole reason they are
  # resolved as subtrees rather than by a rank-column match
  expect_gt(length(unique(s$rank)), 5)
  expect_equal(s$rank[s$taxon == "Aves"], "Class")
  expect_equal(s$rank[s$taxon == "Chelonioidea"], "Superfamily")
  expect_equal(s$rank[s$taxon == "Scleractinia"], "Order")
  expect_setequal(s$rank[s$eov == "fish"], c("Infraphylum", "Parvphylum"))
})

test_that("obis_eov_label() describes each EOV without nesting parentheses", {
  l <- obis_eov_label()
  expect_length(l, 7)
  expect_setequal(names(l), names(obisindicators:::OBIS_EOV))

  # single seed -> "rank Name"; a few -> the names; many -> a count
  expect_equal(unname(l["seaTurtles"]), "Sea turtles (superfamily Chelonioidea)")
  expect_equal(unname(l["seabirds"]),   "Seabirds (class Aves)")
  expect_match(l[["fish"]], "Agnatha, Chondrichthyes, Osteichthyes")
  expect_match(l[["mangroves"]], "19 seed taxa")

  # a nested "((" would render badly in a dropdown
  expect_false(any(grepl("((", l, fixed = TRUE)))
  # every label opens exactly one parenthetical
  expect_true(all(vapply(gregexpr("(", l, fixed = TRUE),
                         function(m) length(m[m > 0]), integer(1)) == 1L))

  expect_equal(unname(obis_eov_label("fish", max_taxa = 1L)),
               "Fish (3 seed taxa: infraphylum/parvphylum)")
  expect_error(obis_eov_label("bogus"), "unknown EOV")
})
