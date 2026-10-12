# obis_h3_export_parquet(): layout, row counts, h3 strings, decade math,
# stats and release.json. one test on the shipped-region demo store (skipped
# when absent), one on the small paper fixture for the EOV / taxon layers.

demo_store <- path.expand(Sys.getenv(
  "OBIS_H3_DEMO_DUCKDB", "~/data/obis/obis_h3_satlantic_v20260728.duckdb"))

h3_ext_ok <- function() tryCatch({
  c0 <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(c0, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(c0, "INSTALL h3 FROM community; LOAD h3;")
  TRUE
}, error = function(e) FALSE)

test_that("export of the demo store: layout, counts, h3, decade math, stats, json", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("jsonlite")
  skip_if_not(file.exists(demo_store), "demo store not found")
  skip_if_not(h3_ext_ok(), "duckdb h3 community extension unavailable")

  con <- obis_store_connect(demo_store)
  dir <- tempfile("export_")
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(dir, recursive = TRUE) },
          add = TRUE)

  files <- obis_h3_export_parquet(con, dir, "v20260728", res_decade = 1:3,
                                  threads = 2L, verbose = FALSE)
  out <- file.path(dir, "v20260728")
  expect_true(all(file.exists(files)))
  expect_true(all(file.exists(file.path(out, c("release.json", "stats.parquet",
                                               "taxon_groups.parquet")))))

  # a partition directory per res present, with the idx_h3 row count each
  cnt <- DBI::dbGetQuery(con, "SELECT res::INTEGER AS res, COUNT(*)::DOUBLE AS n
                               FROM idx_h3 GROUP BY 1 ORDER BY 1")
  for (i in seq_len(nrow(cnt))) {
    d <- file.path(out, "all", paste0("res=", cnt$res[i]))
    expect_true(dir.exists(d))
    got <- DBI::dbGetQuery(con, glue::glue(
      "SELECT COUNT(*)::DOUBLE AS n FROM read_parquet('{d}/**/*.parquet')"))$n
    expect_identical(got, cnt$n[i])
  }

  # decade dirs only for the requested res, inside the default 1960-2020 window
  dd <- list.dirs(file.path(out, "decade", "all"), recursive = TRUE, full.names = FALSE)
  expect_setequal(unique(sub(".*/", "", dd[grepl("/res=", dd)])), paste0("res=", 1:3))
  decs <- as.integer(sub("decade=", "", dd[grepl("^decade=\\d+$", dd)]))
  expect_true(all(decs %in% seq(1960, 2020, 10)))

  # h3 strings decode back to cell_id (BIGINT compare, in SQL: no R doubles)
  bad <- DBI::dbGetQuery(con, glue::glue(
    "SELECT COUNT(*) FILTER (WHERE h3_string_to_h3(h3) <> cell_id) AS bad,
            COUNT(*) FILTER (WHERE h3 <> lower(h3)) AS upper, COUNT(*) AS n
     FROM read_parquet('{out}/all/res=3/*.parquet')"))
  expect_gt(bad$n, 0)
  expect_equal(bad$bad, 0)
  expect_equal(bad$upper, 0)

  # one res-2 cell in the 2000s: n, sp, shannon equal an R computation over the
  # raw occ_h3 rows (res-3 tier rolled to res 2 with h3::h3_to_parent)
  dec <- DBI::dbGetQuery(con, glue::glue(
    "SELECT h3, n::DOUBLE AS n, sp::DOUBLE AS sp, shannon
     FROM read_parquet('{out}/decade/all/decade=2000/res=2/*.parquet')
     ORDER BY n DESC LIMIT 1"))
  occ <- DBI::dbGetQuery(con, "
    SELECT h3_h3_to_string(cell_id) AS cell, species, records::DOUBLE AS records
    FROM occ_h3 WHERE res = 3 AND date_year BETWEEN 2000 AND 2009")
  u <- unique(occ$cell)  # h3::h3_to_parent() is not vectorised
  occ$parent <- vapply(u, h3::h3_to_parent, character(1), res = 2)[occ$cell]
  ref <- occ |>
    dplyr::filter(parent == dec$h3) |>
    dplyr::group_by(species) |>
    dplyr::summarise(ni = sum(records), .groups = "drop") |>
    dplyr::mutate(p = ni / sum(ni)) |>
    dplyr::summarise(n = sum(ni), sp = dplyr::n(), shannon = -sum(p * log(p)))
  expect_identical(dec$n,  ref$n)
  expect_identical(dec$sp, as.numeric(ref$sp))
  expect_equal(dec$shannon, ref$shannon, tolerance = 1e-10)

  # stats: one row per layer x key x decade x res x variable
  st <- DBI::dbGetQuery(con, glue::glue(
    "SELECT * FROM read_parquet('{out}/stats.parquet')"))
  expect_setequal(unique(st$variable), c("n", "sp", "shannon", "simpson", "es"))
  expect_equal(nrow(dplyr::distinct(st, layer, key, rank, decade, res, variable)),
               nrow(st))
  expect_equal(sum(st$layer == "all"), nrow(cnt) * 5L)
  n_dec <- length(list.files(file.path(out, "decade", "all"), "\\.parquet$",
                             recursive = TRUE))
  expect_equal(sum(st$layer == "decade_all"), n_dec * 5L)
  s3 <- st[st$layer == "all" & st$res == 3 & st$variable == "n", ]
  expect_equal(s3$n_cells, cnt$n[cnt$res == 3])
  expect_true(s3$min <= s3$p02 && s3$p02 <= s3$p50 && s3$p50 <= s3$p98 &&
                s3$p98 <= s3$max)

  # release.json parses and lists the layers with their row counts
  js <- jsonlite::read_json(file.path(out, "release.json"))
  expect_equal(js$release, "v20260728")
  expect_null(js$worms_version)  # OBIS_WORMS_VERSION unset: the key is left out
  expect_equal(js$obis_snapshot, "2026-07-28")
  expect_true(all(c("all", "decade_all") %in% names(js$layers)))
  expect_equal(js$layers$all$rows, sum(cnt$n))
  n_par <- DBI::dbGetQuery(con, "
    SELECT res::INTEGER AS res, COUNT(DISTINCT h3_cell_to_parent(cell_id, res - 4))::INTEGER AS n
    FROM idx_h3 WHERE res >= 6 GROUP BY 1 ORDER BY 1")
  expect_equal(js$layers$all$files, sum(cnt$res <= 5) + sum(n_par$n))
  expect_equal(unlist(js$layers$all$parent_res), c("6" = 2L, "7" = 3L))
  expect_setequal(names(js$columns),
                  c("h3", "cell_id", "n", "sp", "shannon", "simpson", "es"))
  mf <- DBI::dbGetQuery(con, glue::glue(
    "SELECT * FROM read_parquet('{out}/files.parquet')"))
  expect_equal(nrow(mf), length(files) - 2L)  # all but release.json, files.parquet
  expect_equal(sum(mf$rows[mf$layer == "all"]), sum(cnt$n))
  expect_equal(js$files$n_files, length(files) - 1L)

  # idempotence: refuses to clobber, replaces with overwrite = TRUE
  expect_error(obis_h3_export_parquet(con, dir, "v20260728", verbose = FALSE),
               "overwrite")
  files2 <- obis_h3_export_parquet(con, dir, "v20260728", res_decade = 1:3,
                                   overwrite = TRUE, verbose = FALSE)
  expect_setequal(basename(dirname(files2)), basename(dirname(files)))
  expect_equal(length(files2), length(files))
})

test_that("export splits the fine res of the demo store by parent cell", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("jsonlite")
  skip_if_not_installed("h3")
  skip_if_not(file.exists(demo_store), "demo store not found")
  skip_if_not(h3_ext_ok(), "duckdb h3 community extension unavailable")

  con <- obis_store_connect(demo_store)
  dir <- tempfile("export_")
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(dir, recursive = TRUE) },
          add = TRUE)
  # parent_min_rows = 0: every taxon with res 6/7 rows is split too
  obis_h3_export_parquet(con, dir, "v1", res_decade = 1L, parent_min_rows = 0,
                         max_open = 500L, threads = 2L, verbose = FALSE)
  out <- file.path(dir, "v1")
  mf  <- DBI::dbGetQuery(con, glue::glue("SELECT * FROM read_parquet('{out}/files.parquet')"))

  # res <= 5 stay one whole file each, with no parent
  for (r in 1:5) {
    expect_true(file.exists(file.path(out, "all", paste0("res=", r), "data_0.parquet")))
    expect_true(all(is.na(mf$parent[mf$layer == "all" & grepl(paste0("/res=", r, "/"), mf$path)])))
  }
  for (pr in list(c(6L, 2L), c(7L, 3L))) {
    r <- pr[1]; rp <- pr[2]
    d <- file.path(out, "all", paste0("res=", r))
    # no whole file left; partition count = distinct parents in the store
    expect_false(file.exists(file.path(d, "data_0.parquet")))
    want <- DBI::dbGetQuery(con, glue::glue(
      "SELECT COUNT(DISTINCT h3_cell_to_parent(cell_id, {rp}))::INTEGER AS np,
              COUNT(*)::DOUBLE AS n FROM idx_h3 WHERE res = {r}"))
    pdirs <- list.dirs(d, recursive = FALSE, full.names = FALSE)
    expect_true(all(grepl("^p=[0-9a-f]+$", pdirs)))
    expect_length(pdirs, want$np)
    expect_true(all(file.exists(file.path(d, pdirs, "data_0.parquet"))))
    # row totals unchanged
    got <- DBI::dbGetQuery(con, glue::glue(
      "SELECT COUNT(*)::DOUBLE AS n FROM read_parquet('{d}/*/*.parquet')"))$n
    expect_identical(got, want$n)
    # every h3 in a partition has the partition key as its parent (h3 R package)
    smp <- DBI::dbGetQuery(con, glue::glue(
      "SELECT h3, p FROM read_parquet('{d}/*/*.parquet', hive_partitioning = true,
                                       hive_types = {{'p': 'VARCHAR'}})
       USING SAMPLE 300 ROWS"))
    expect_equal(nrow(smp), 300L)
    expect_identical(unname(vapply(smp$h3, h3::h3_to_parent, character(1), res = rp)), smp$p)
    # the manifest: one row per partition, parent = path key, at the parent res
    m <- mf[mf$layer == "all" & grepl(paste0("^all/res=", r, "/"), mf$path), ]
    expect_equal(nrow(m), want$np)
    expect_identical(m$parent, sub(".*/p=([0-9a-f]+)/.*", "\\1", m$path))
    expect_true(all(vapply(m$parent[1:5], h3::h3_get_resolution, numeric(1)) == rp))
    expect_equal(sum(m$rows), want$n)
  }

  # the taxon layer splits by base cell (res 0); totals unchanged (the demo
  # store's idx_h3_taxon is empty; the paper fixture test covers real rows)
  tx <- DBI::dbGetQuery(con, "
    SELECT COUNT(*)::DOUBLE AS n,
           COUNT(DISTINCT (rank, taxon, res, h3_cell_to_parent(cell_id, 0)))::INTEGER AS np
    FROM idx_h3_taxon WHERE res >= 6")
  mt <- mf[mf$layer == "taxon" & !is.na(mf$parent), ]
  expect_equal(nrow(mt), tx$np)
  expect_equal(sum(mt$rows), tx$n)
  expect_true(all(vapply(unique(mt$parent), h3::h3_get_resolution, numeric(1)) == 0))
  expect_equal(sum(mf$rows[mf$layer == "taxon"]),
               DBI::dbGetQuery(con, "SELECT COUNT(*)::DOUBLE AS n FROM idx_h3_taxon")$n)

  # stats still cover res 6/7 (read through the parent partitions)
  st <- DBI::dbGetQuery(con, glue::glue(
    "SELECT res, n_cells FROM read_parquet('{out}/stats.parquet')
     WHERE layer = 'all' AND variable = 'n' ORDER BY res"))
  cnt <- DBI::dbGetQuery(con, "SELECT res::INTEGER AS res, COUNT(*)::DOUBLE AS n
                               FROM idx_h3 GROUP BY 1 ORDER BY 1")
  expect_equal(st$n_cells, cnt$n)

  # release.json documents it
  js <- jsonlite::read_json(file.path(out, "release.json"))
  expect_true("parent" %in% unlist(js$files$columns))
  expect_equal(js$parents$parent_min_rows, 0)

  # parent_min_rows above every count keeps everything whole
  obis_h3_export_parquet(con, dir, "v0", res_decade = 1L, parent_min_rows = 1e9,
                         threads = 2L, verbose = FALSE)
  m0 <- DBI::dbGetQuery(con, glue::glue(
    "SELECT * FROM read_parquet('{file.path(dir, 'v0')}/files.parquet')"))
  expect_true(all(is.na(m0$parent)))
  expect_equal(sum(m0$layer == "all"), 7L)
})

test_that("export of the paper fixture: eov, taxon, decade_eov layers", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("jsonlite")
  skip_if_not_installed("h3")
  skip_if_not(h3_ext_ok(), "duckdb h3 community extension unavailable")

  fx  <- make_paper_fixture()
  con <- fx$con
  dir <- tempfile("export_")
  on.exit({
    DBI::dbDisconnect(con, shutdown = TRUE); unlink(fx$db)
    unlink(dir, recursive = TRUE) }, add = TRUE)

  # idx_h3_taxon as the build makes it, with one name that needs encoding
  DBI::dbExecute(con, "
    CREATE TABLE idx_h3_taxon (
      rank VARCHAR, taxon VARCHAR, res UTINYINT, cell_id BIGINT,
      n BIGINT, sp BIGINT, shannon DOUBLE, simpson DOUBLE, es DOUBLE);")
  for (rk in H3T_IDX_RANKS) for (r in 1:7)
    DBI::dbExecute(con, .h3t_idx_taxon_sql(rk, r, 50L))
  DBI::dbExecute(con, "UPDATE idx_h3_taxon SET taxon = 'Reptilia incertae sedis'
                       WHERE taxon = 'Reptilia'")

  withr::local_envvar(OBIS_WORMS_VERSION = "2026-10-01")  # as refresh_obis_h3.sh passes it
  obis_h3_export_parquet(con, dir, "test", res_decade = c(5L, 7L), verbose = FALSE)
  out <- file.path(dir, "test")
  expect_equal(jsonlite::read_json(file.path(out, "release.json"))$worms_version, "2026-10-01")

  # eov layer: row count per (eov, res) equals idx_h3_eov
  for (k in c("seaTurtles", "seabirds")) for (r in c(1L, 7L)) {
    want <- DBI::dbGetQuery(con, glue::glue(
      "SELECT COUNT(*)::DOUBLE AS n FROM idx_h3_eov WHERE eov = '{k}' AND res = {r}"))$n
    got  <- DBI::dbGetQuery(con, glue::glue(
      "SELECT COUNT(*)::DOUBLE AS n FROM read_parquet('{out}/eov/eov={k}/res={r}/*.parquet')"))$n
    expect_identical(got, want)
  }

  # decade x EOV: seaTurtles at res 5 — A+B merge (2015: 120 + 45), C apart (60);
  # Caretta in the 1970s at A (80) and C (200). seabirds have no 1970s records.
  dt <- function(dec) DBI::dbGetQuery(con, glue::glue(
    "SELECT n::DOUBLE AS n, sp::DOUBLE AS sp, es
     FROM read_parquet('{out}/decade/eov/eov=seaTurtles/decade={dec}/res=5/*.parquet')
     ORDER BY n"))
  d10 <- dt(2010)
  expect_equal(d10$n, c(60, 165))
  expect_equal(d10$sp, c(1, 1))
  expect_equal(d10$es, c(1, 1))
  expect_equal(dt(1970)$n, c(80, 200))
  expect_false(dir.exists(file.path(out, "decade/eov/eov=seabirds/decade=1970")))
  # res 7 keeps A and B apart; the all-taxa decade adds the gull at D
  expect_equal(nrow(DBI::dbGetQuery(con, glue::glue(
    "SELECT * FROM read_parquet('{out}/decade/eov/eov=seaTurtles/decade=2010/res=7/*.parquet')"))), 3L)
  expect_equal(DBI::dbGetQuery(con, glue::glue(
    "SELECT SUM(n)::DOUBLE AS n FROM read_parquet('{out}/decade/all/decade=2010/res=5/*.parquet')"))$n,
    120 + 45 + 60 + 300)

  # taxon names are hive-encoded on disk and decode on read
  enc <- file.path(out, "taxon/rank=class/taxon=Reptilia%20incertae%20sedis/res=3")
  expect_true(dir.exists(enc))
  got <- DBI::dbGetQuery(con, glue::glue(
    "SELECT DISTINCT taxon FROM read_parquet('{out}/taxon/*/*/*/*.parquet',
       hive_partitioning = true, hive_types = {{'rank': 'VARCHAR', 'taxon': 'VARCHAR', 'res': 'INTEGER'}})
     WHERE rank = 'class' ORDER BY 1"))$taxon
  expect_equal(got, c("Aves", "Reptilia incertae sedis"))

  # taxon_groups: one row per (rank, taxon) plus one per EOV, with real paths
  tg <- DBI::dbGetQuery(con, glue::glue(
    "SELECT * FROM read_parquet('{out}/taxon_groups.parquet')"))
  want <- DBI::dbGetQuery(con, "SELECT COUNT(DISTINCT (rank, taxon)) AS n FROM idx_h3_taxon")$n
  expect_equal(sum(tg$kind == "taxon"), want)
  expect_setequal(tg$taxon[tg$kind == "eov"], c("seaTurtles", "seabirds"))
  expect_true(all(dir.exists(file.path(out, tg$path))))
  rp <- tg[tg$taxon == "Reptilia incertae sedis", ]
  expect_equal(rp$path, "taxon/rank=class/taxon=Reptilia%20incertae%20sedis")
  expect_equal(rp$url_path, "taxon/rank=class/taxon=Reptilia%2520incertae%2520sedis")
  expect_equal(rp$n, 120 + 80 + 45 + 200 + 60)
  expect_equal(tg$n[tg$taxon == "seabirds"], 300)

  # stats cover every layer, one row per key x decade x res x variable
  st <- DBI::dbGetQuery(con, glue::glue("SELECT * FROM read_parquet('{out}/stats.parquet')"))
  expect_setequal(unique(st$layer), c("all", "eov", "taxon", "decade_all", "decade_eov"))
  expect_equal(nrow(dplyr::distinct(st, layer, key, rank, decade, res, variable)), nrow(st))
  expect_equal(sum(st$layer == "eov"), 2L * 7L * 5L)
  es_t <- st[st$layer == "eov" & st$key == "seaTurtles" & st$res == 7 & st$variable == "es", ]
  expect_equal(es_t$n_cells, 2)  # A 200, C 260 have ES50; B (45) is NULL -> not counted
  # regression (2026-10-12): stats are computed per layer and variable, since one UNPIVOT over every
  # layer ran out of memory once the family rank was added; same rows, values and column types
  ty <- DBI::dbGetQuery(con, glue::glue("DESCRIBE SELECT * FROM read_parquet('{out}/stats.parquet')"))
  expect_equal(setNames(ty$column_type, ty$column_name)[c("decade", "res", "n_cells")],
               c(decade = "INTEGER", res = "INTEGER", n_cells = "BIGINT"))
  ref <- DBI::dbGetQuery(con, glue::glue("
    WITH d AS (SELECT eov AS key, res, n::DOUBLE AS n, sp::DOUBLE AS sp, shannon::DOUBLE AS shannon,
                      simpson::DOUBLE AS simpson, es::DOUBLE AS es
               FROM read_parquet('{out}/eov/*/*/*.parquet', hive_partitioning = true,
                                 hive_types = {{'eov': 'VARCHAR', 'res': 'INTEGER'}})),
         u AS (SELECT * FROM d UNPIVOT INCLUDE NULLS (value FOR variable IN (n, sp, shannon, simpson, es)))
    SELECT key, res, variable, MIN(value) AS min, quantile_cont(value, 0.5) AS p50,
           MAX(value) AS max, COUNT(value) AS n_cells
    FROM u GROUP BY ALL ORDER BY key, res, variable"))
  got <- st[st$layer == "eov", c("key", "res", "variable", "min", "p50", "max", "n_cells")]
  got <- got[order(got$key, got$res, got$variable), ]
  rownames(got) <- NULL
  expect_equal(got, ref, ignore_attr = TRUE)
  js <- jsonlite::read_json(file.path(out, "release.json"))
  expect_setequal(names(js$layers), c("all", "eov", "taxon", "decade_all", "decade_eov"))
  expect_null(js$layers$taxon$parent_res)  # tiny fixture: below parent_min_rows

  # split every fine partition: taxon by base cell, encoded names kept
  obis_h3_export_parquet(con, dir, "split", res_decade = 5L, parent_min_rows = 0,
                         verbose = FALSE)
  sp <- file.path(dir, "split")
  mf <- DBI::dbGetQuery(con, glue::glue("SELECT * FROM read_parquet('{sp}/files.parquet')"))
  for (r in 6:7) {
    want <- DBI::dbGetQuery(con, glue::glue(
      "SELECT COUNT(DISTINCT (rank, taxon, h3_cell_to_parent(cell_id, 0)))::INTEGER AS np,
              COUNT(*)::DOUBLE AS n FROM idx_h3_taxon WHERE res = {r}"))
    m <- mf[mf$layer == "taxon" & grepl(paste0("/res=", r, "/p="), mf$path), ]
    expect_equal(nrow(m), want$np)
    expect_equal(sum(m$rows), want$n)
    expect_true(all(vapply(m$parent, h3::h3_get_resolution, numeric(1)) == 0))
  }
  expect_true(any(startsWith(
    mf$url_path, "taxon/rank=class/taxon=Reptilia%2520incertae%2520sedis/res=7/p=")))
  e7 <- mf[mf$layer == "eov" & grepl("^eov/eov=seaTurtles/res=7/", mf$path), ]
  expect_true(all(vapply(e7$parent, h3::h3_get_resolution, numeric(1)) == 3))
  js <- jsonlite::read_json(file.path(sp, "release.json"))
  expect_equal(unlist(js$layers$taxon$parent_res), c("6" = 0L, "7" = 0L))
  expect_equal(unlist(js$layers$eov$parent_res), c("6" = 2L, "7" = 3L))
  # stats from split files equal those from whole files
  s_whole <- DBI::dbGetQuery(con, glue::glue(
    "SELECT * FROM read_parquet('{out}/stats.parquet') WHERE res >= 6 AND decade IS NULL ORDER BY ALL"))
  s_split <- DBI::dbGetQuery(con, glue::glue(
    "SELECT * FROM read_parquet('{sp}/stats.parquet') WHERE res >= 6 AND decade IS NULL ORDER BY ALL"))
  expect_equal(s_split, s_whole)
})

test_that("export writes exactly one data_0.parquet per partition", {
  # regression: on the global store (~11k taxon partitions) DuckDB split 251
  # partitions into data_0 + data_1 once more than partitioned_write_max_open_files
  # were open; the export now lifts that cap. needs enough rows to trigger it.
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("jsonlite")
  skip_if_not(h3_ext_ok(), "duckdb h3 community extension unavailable")

  con <- DBI::dbConnect(duckdb::duckdb())
  dir <- tempfile("export_")
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(dir, recursive = TRUE) },
          add = TRUE)
  DBI::dbExecute(con, "LOAD h3;")
  DBI::dbExecute(con, "
    CREATE TABLE idx_h3 AS
    SELECT 1::UTINYINT AS res, 581690000000000000 + i AS cell_id, 1::BIGINT AS n,
           1::BIGINT AS sp, 0::DOUBLE AS shannon, 1::DOUBLE AS simpson,
           NULL::DOUBLE AS es
    FROM range(10) t(i);")
  DBI::dbExecute(con, "
    CREATE TABLE occ_h3 (res UTINYINT, cell_id BIGINT, aphiaid BIGINT,
      species VARCHAR, date_year SMALLINT, records BIGINT);")
  DBI::dbExecute(con, "
    CREATE TABLE idx_h3_taxon AS
    SELECT 'class' AS rank, 'T' || (i % 300) AS taxon, (1 + i % 2)::UTINYINT AS res,
           581690000000000000 + i AS cell_id, 1::BIGINT AS n, 1::BIGINT AS sp,
           0::DOUBLE AS shannon, 1::DOUBLE AS simpson, NULL::DOUBLE AS es
    FROM range(1000000) t(i);")
  DBI::dbExecute(con, "SET partitioned_write_max_open_files = 2;")

  obis_h3_export_parquet(con, dir, "test", res_decade = 1L, verbose = FALSE)
  pq <- list.files(file.path(dir, "test", "taxon"), "\\.parquet$", recursive = TRUE)
  expect_length(pq, 300L)  # taxon T<k> always lands in one res (k % 2)
  expect_true(all(basename(pq) == "data_0.parquet"))
  # the setting is reset to its default afterwards
  expect_equal(DBI::dbGetQuery(con,
    "SELECT current_setting('partitioned_write_max_open_files') AS v")$v, 100)
})

test_that(".obisindicators_version() reads the checkout's DESCRIPTION, else the installed package", {
  root <- tempfile("pkg_"); dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  writeLines(c("Package: obisindicators", "Version: 9.8.7"), file.path(root, "DESCRIPTION"))
  expect_identical(.obisindicators_version(root), "9.8.7")

  # another package's DESCRIPTION, or no DESCRIPTION, falls back to the installed version (or NA)
  writeLines(c("Package: other", "Version: 1.0.0"), file.path(root, "DESCRIPTION"))
  installed <- tryCatch(as.character(utils::packageVersion("obisindicators")),
                        error = function(e) NA_character_)
  expect_identical(.obisindicators_version(root), installed)
  expect_identical(.obisindicators_version(""), installed)
  expect_identical(.obisindicators_version(file.path(root, "missing")), installed)
})

