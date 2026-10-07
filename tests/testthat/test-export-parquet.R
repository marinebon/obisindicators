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
      "SELECT COUNT(*)::DOUBLE AS n FROM read_parquet('{d}/*.parquet')"))$n
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
  expect_equal(js$obis_snapshot, "2026-07-28")
  expect_true(all(c("all", "decade_all") %in% names(js$layers)))
  expect_equal(js$layers$all$rows, sum(cnt$n))
  expect_equal(js$layers$all$files, nrow(cnt))
  expect_setequal(names(js$columns),
                  c("h3", "cell_id", "n", "sp", "shannon", "simpson", "es"))
  expect_equal(length(js$files), length(files) - 1L)  # all but release.json

  # idempotence: refuses to clobber, replaces with overwrite = TRUE
  expect_error(obis_h3_export_parquet(con, dir, "v20260728", verbose = FALSE),
               "overwrite")
  files2 <- obis_h3_export_parquet(con, dir, "v20260728", res_decade = 1:3,
                                   overwrite = TRUE, verbose = FALSE)
  expect_setequal(basename(dirname(files2)), basename(dirname(files)))
  expect_equal(length(files2), length(files))
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

  obis_h3_export_parquet(con, dir, "test", res_decade = c(5L, 7L), verbose = FALSE)
  out <- file.path(dir, "test")

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
  js <- jsonlite::read_json(file.path(out, "release.json"))
  expect_setequal(names(js$layers), c("all", "eov", "taxon", "decade_all", "decade_eov"))
})
