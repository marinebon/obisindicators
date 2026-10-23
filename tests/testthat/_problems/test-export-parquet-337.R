# Extracted from test-export-parquet.R:337

# setup ------------------------------------------------------------------------
library(testthat)
test_env <- simulate_test_env(package = "obisindicators", path = "..")
attach(test_env, warn.conflicts = FALSE)

# prequel ----------------------------------------------------------------------
demo_store <- path.expand(Sys.getenv(
  "OBIS_H3_DEMO_DUCKDB", "~/data/obis/obis_h3_satlantic_v20260728.duckdb"))
h3_ext_ok <- function() tryCatch({
  c0 <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(c0, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(c0, "INSTALL h3 FROM community; LOAD h3;")
  TRUE
}, error = function(e) FALSE)

# test -------------------------------------------------------------------------
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
DBI::dbExecute(con, "
    CREATE TABLE idx_h3_taxon (
      rank VARCHAR, taxon VARCHAR, res UTINYINT, cell_id BIGINT,
      n BIGINT, sp BIGINT, shannon DOUBLE, simpson DOUBLE, es DOUBLE);")
for (rk in H3T_IDX_RANKS) for (r in 1:7)
    DBI::dbExecute(con, .h3t_idx_taxon_sql(rk, r, 50L))
DBI::dbExecute(con, "UPDATE idx_h3_taxon SET taxon = 'Reptilia incertae sedis'
                       WHERE taxon = 'Reptilia'")
withr::local_envvar(OBIS_WORMS_VERSION = "2026-10-01", OBIS_DATA_DATE = "2026-10-11")
obis_h3_export_parquet(con, dir, "v20261012", res_decade = c(5L, 7L), verbose = FALSE)
out <- file.path(dir, "v20261012")
js  <- jsonlite::read_json(file.path(out, "release.json"))
expect_equal(js$worms_version, "2026-10-01")
expect_equal(js$obis_snapshot, "2026-10-11")
expect_equal(js$release, "v20261012")
for (k in c("seaTurtles", "seabirds")) for (r in c(1L, 7L)) {
    want <- DBI::dbGetQuery(con, glue::glue(
      "SELECT COUNT(*)::DOUBLE AS n FROM idx_h3_eov WHERE eov = '{k}' AND res = {r}"))$n
    got  <- DBI::dbGetQuery(con, glue::glue(
      "SELECT COUNT(*)::DOUBLE AS n FROM read_parquet('{out}/eov/eov={k}/res={r}/*.parquet')"))$n
    expect_identical(got, want)
  }
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
expect_equal(nrow(DBI::dbGetQuery(con, glue::glue(
    "SELECT * FROM read_parquet('{out}/decade/eov/eov=seaTurtles/decade=2010/res=7/*.parquet')"))), 3L)
expect_equal(DBI::dbGetQuery(con, glue::glue(
    "SELECT SUM(n)::DOUBLE AS n FROM read_parquet('{out}/decade/all/decade=2010/res=5/*.parquet')"))$n,
    120 + 45 + 60 + 300)
enc <- file.path(out, "taxon/rank=class/taxon=Reptilia%20incertae%20sedis/res=3")
expect_true(dir.exists(enc))
got <- DBI::dbGetQuery(con, glue::glue(
    "SELECT DISTINCT taxon FROM read_parquet('{out}/taxon/*/*/*/*.parquet',
       hive_partitioning = true, hive_types = {{'rank': 'VARCHAR', 'taxon': 'VARCHAR', 'res': 'INTEGER'}})
     WHERE rank = 'class' ORDER BY 1"))$taxon
expect_equal(got, c("Aves", "Reptilia incertae sedis"))
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
st <- DBI::dbGetQuery(con, glue::glue("SELECT * FROM read_parquet('{out}/stats.parquet')"))
expect_setequal(unique(st$layer), c("all", "eov", "taxon", "decade_all", "decade_eov",
                                      "year_all", "year_eov"))
expect_equal(nrow(dplyr::distinct(st, layer, key, rank, decade, year, res, variable)), nrow(st))
expect_equal(sum(st$layer == "eov"), 2L * 7L * 5L)
es_t <- st[st$layer == "eov" & st$key == "seaTurtles" & st$res == 7 & st$variable == "es", ]
expect_equal(es_t$n_cells, 2)
ty <- DBI::dbGetQuery(con, glue::glue("DESCRIBE SELECT * FROM read_parquet('{out}/stats.parquet')"))
expect_equal(setNames(ty$column_type, ty$column_name)[c("decade", "year", "res", "n_cells")],
               c(decade = "INTEGER", year = "INTEGER", res = "INTEGER", n_cells = "BIGINT"))
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
expect_setequal(names(js$layers), c("all", "eov", "taxon", "decade_all", "decade_eov",
                                      "year_all", "year_eov", "species"))
