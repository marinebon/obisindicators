# supplementing the bulk WoRMS download with per-id REST lookups, so aphiaids
# OBIS carries but taxon.txt lacks (notably algae) stop being invisible to the
# children walk. see R/taxon_gapfill.R.

test_that("obis_taxon_orphans() finds occ_h3 aphiaids missing from taxon", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")

  fx <- make_gapfill_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  o <- obis_taxon_orphans(con)
  expect_setequal(o$taxonID, c(3002, 9999))
  expect_false(1111 %in% o$taxonID)             # already in taxon
  # counted at ONE resolution tier only — occ_h3 rolls the same records up at
  # several, so a naive SUM would double-count (750, not 1500)
  expect_equal(o$records[o$taxonID == 3002], 750)
  expect_equal(o$records[o$taxonID == 9999], 7)
  # most-records-first ordering
  expect_equal(o$taxonID[1], 3002)
  # min_records filters the long tail
  expect_setequal(obis_taxon_orphans(con, min_records = 100)$taxonID, 3002)
})

test_that("obis_taxon_fill_gaps() closes the ancestor chain, not just the orphan", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")

  fx <- make_gapfill_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)
  stub <- make_fetch_stub(fx$worms)

  res <- obis_taxon_fill_gaps(con, fetch = stub$fn, verbose = FALSE)

  # the orphan species AND both missing ancestors were inserted — inserting
  # only 3002 would leave it disconnected from any seed above it
  expect_setequal(res$added$taxonID, c(3002, 3001, 3000))
  expect_setequal(
    DBI::dbGetQuery(con, "SELECT taxonID FROM taxon")$taxonID,
    c(1000, 1100, 1110, 1111, 3000, 3001, 3002))

  # closure took more than one round: 3001/3000 are only discoverable from the
  # parent edge of a row inserted in the previous round
  expect_gt(length(stub$calls()), 1L)
  expect_true(3002 %in% stub$calls()[[1]])
  expect_false(any(c(3001, 3000) %in% stub$calls()[[1]]))

  # records made reachable is reported from the pre-fill orphan scan
  expect_equal(res$records_recovered, 757)
})

test_that("gap-fill makes the orphan reachable by the children walk", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")

  fx <- make_gapfill_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  # before: the class seed resolves to nothing, so its 750 records are invisible
  expect_equal(nrow(obis_taxon_children(3000, con)), 0)

  obis_taxon_fill_gaps(con, fetch = make_fetch_stub(fx$worms)$fn, verbose = FALSE)

  # after: the full subtree resolves, at ranks the DwC columns never carried
  ch <- obis_taxon_children(3000, con)
  expect_setequal(ch$taxonID, c(3000, 3001, 3002))
  expect_equal(ch$depth_level[ch$taxonID == 3002], 2)

  # ...and the aphiaid filter now actually selects those occurrences
  n <- DBI::dbGetQuery(con, paste0(
    "WITH RECURSIVE ", obisindicators:::.h3t_taxon_tree_cte(3000),
    " SELECT SUM(records) AS n FROM occ_h3
       WHERE res = 3 AND aphiaid IN (SELECT taxonID FROM taxon_tree)"))$n
  expect_equal(n, 750)
})

test_that("ids WoRMS cannot resolve are recorded, not retried forever", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")

  fx <- make_gapfill_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)
  stub <- make_fetch_stub(fx$worms)

  res <- obis_taxon_fill_gaps(con, fetch = stub$fn, verbose = FALSE)

  expect_true(9999 %in% res$unresolved)
  expect_lt(res$rounds, 12L)                     # terminated well before the guard
  # 9999 was asked for exactly once, then remembered as unresolvable
  expect_equal(sum(vapply(stub$calls(), function(x) 9999 %in% x, logical(1))), 1L)
  # it remains an orphan, honestly reported rather than silently dropped
  expect_setequal(obis_taxon_orphans(con)$taxonID, 9999)
})

test_that("hitting max_rounds warns and reports the tree as NOT closed", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")

  fx <- make_gapfill_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  # one round only: 3002 lands but its ancestors 3001/3000 do not, so a walk
  # seeded at the class still cannot reach the species — this must not pass
  # silently (it was the real failure mode on the first global run)
  expect_warning(
    res <- obis_taxon_fill_gaps(con, fetch = make_fetch_stub(fx$worms)$fn,
                                max_rounds = 1L, verbose = FALSE),
    "NOT closed")
  expect_false(res$closed)
  expect_setequal(res$added$taxonID, 3002)
  expect_equal(nrow(obis_taxon_children(3000, con)), 0)   # still unreachable

  # and a full run does reach closure, without warning
  expect_silent(
    res2 <- obis_taxon_fill_gaps(con, fetch = make_fetch_stub(fx$worms)$fn,
                                 verbose = FALSE))
  expect_true(res2$closed)
})

test_that("fill is idempotent — a second pass adds nothing", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")

  fx <- make_gapfill_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  obis_taxon_fill_gaps(con, fetch = make_fetch_stub(fx$worms)$fn, verbose = FALSE)
  n1  <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM taxon")$n

  res <- obis_taxon_fill_gaps(con, fetch = make_fetch_stub(fx$worms)$fn, verbose = FALSE)
  n2  <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM taxon")$n

  expect_equal(n1, n2)
  expect_equal(nrow(res$added), 0)
})

test_that("a FAILED request is retried, not written off as unresolvable", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")

  fx <- make_gapfill_fixture(); con <- fx$con
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db) }, add = TRUE)

  # a fetcher whose FIRST call fails outright (transport error), reporting its
  # ids via the failed_ids attribute — as wm_aphia_records() does for a batch
  # whose request never succeeded. This is the bug that silently discarded 2,250
  # resolvable algae ids (45 whole batches) on the first real global run.
  n <- 0L
  flaky <- function(aphiaid) {
    n <<- n + 1L
    if (n == 1L) {
      out <- obisindicators:::.wm_empty_taxon_df()
      attr(out, "failed_ids") <- as.integer(aphiaid)
      return(out)
    }
    fx$worms[fx$worms$taxonID %in% as.integer(aphiaid), , drop = FALSE]
  }

  res <- obis_taxon_fill_gaps(con, fetch = flaky, verbose = FALSE)

  # 3002 was in the failed batch — it must NOT be branded unresolvable, and the
  # retry must have gone on to resolve it and close its ancestry
  expect_false(3002 %in% res$unresolved)
  expect_setequal(res$added$taxonID, c(3002, 3001, 3000))
  expect_true(res$closed)
  # 9999 was also in that batch but is genuinely absent; once a request DOES
  # succeed without it, it is correctly recorded as unresolvable
  expect_true(9999 %in% res$unresolved)
})

test_that("parallel-request args adapt to the installed httr2 version", {
  skip_if_not_installed("httr2")

  # httr2 >= 1.1 (a current laptop)
  new_fn <- function(reqs, paths, on_error, progress, max_active, mock) NULL
  a <- obisindicators:::.wm_parallel_args(list("r"), 4L, new_fn)
  expect_equal(a$max_active, 4L)
  expect_null(a$pool)
  expect_equal(a$on_error, "continue")

  # httr2 1.0.x (the msens plumber container) — concurrency rides on a curl pool
  old_fn <- function(reqs, paths, pool, on_error, progress) NULL
  b <- obisindicators:::.wm_parallel_args(list("r"), 4L, old_fn)
  expect_null(b$max_active)
  expect_s3_class(b$pool, "curl_multi")
  expect_equal(b$on_error, "continue")

  # a hypothetical version with neither must still produce a callable arg list
  bare <- function(reqs) NULL
  d <- obisindicators:::.wm_parallel_args(list("r"), 4L, bare)
  expect_length(d, 1L)
})

test_that("wm_aphia_records() parses live WoRMS responses", {
  skip_if_not_installed("httr2")
  skip_on_cran()
  skip_if_offline()

  # 1836 Aves (class), 148899 Bacillariophyceae (class), 999999999 unknown
  d <- wm_aphia_records(c(1836, 148899, 999999999), verbose = FALSE)

  expect_setequal(names(d), names(obisindicators:::.wm_empty_taxon_df()))
  expect_setequal(d$taxonID, c(1836, 148899))
  expect_false(999999999 %in% d$taxonID)          # unmatched ids are dropped
  expect_equal(d$scientificName[d$taxonID == 1836], "Aves")
  expect_equal(d$taxonRank[d$taxonID == 1836], "Class")
  # the edge the closure walk depends on must come back populated
  expect_true(all(!is.na(d$parentNameUsageID)))
  expect_equal(d$acceptedNameUsageID[d$taxonID == 148899], 148899)
})
