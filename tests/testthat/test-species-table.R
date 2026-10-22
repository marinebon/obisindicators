# the year layers and the species x hex x count table on the synthetic store
# of helper-species.R: exact rows for each SQL builder, the per-partition
# writer, the heads, the export layout and release.json, the subtree parity
# against .h3t_indicators_sql(), and the STAC Collection against the h3 profile.

skip_species <- function() {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("jsonlite")
  skip_if_not_installed("h3")
  skip_if_not(h3_ext_ok(), "duckdb h3 community extension unavailable")
}

# the fixture cell name of each h3 string
cell_name <- function(h3, cl = species_fixture_cells()) {
  cl <- unlist(cl[setdiff(names(cl), "Q")])
  names(cl)[match(h3, cl)]
}

test_that("obis_h3_species_lookup_sql(): one row per aphiaid, name_key per name, lineage from self", {
  skip_species()
  con <- make_species_fixture()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  lk <- DBI::dbGetQuery(con, paste0(
    "SELECT aphiaid::INTEGER AS aphiaid, name_key, species, class, records::INTEGER AS records,
            lineage::VARCHAR AS lineage
     FROM (", obis_h3_species_lookup_sql(), ")"))
  expect_equal(lk, data.frame(
    aphiaid  = c(16L, 18L, 20L, 23L, 24L, 33L, 41L),
    name_key = c(6L, 4L, 2L, 3L, 6L, 1L, 5L),
    species  = c("Tursiops truncatus", "Orcinus orca", "Grampus orca", "Larus argentatus",
                 "Tursiops truncatus", "Corallina officinalis", "Pikaia gracilens"),
    class    = c("Mammalia", "Mammalia", "Mammalia", "Aves", "Mammalia", "Florideophyceae", NA),
    records  = c(55L, 45L, 12L, 115L, 10L, 70L, 65L),
    lineage  = c("[16, 15, 14, 13, 11, 10, 2, 1]", "[18, 17, 14, 13, 11, 10, 2, 1]",
                 # the synonym keeps its own parent (19 Grampus), not its accepted name's (17)
                 "[20, 19, 14, 13, 11, 10, 2, 1]", "[23, 22, 21, 12, 10, 2, 1]",
                 "[24, 15, 14, 13, 11, 10, 2, 1]", "[33, 32, 31, 30, 3, 1]", "[41, 10, 2, 1]"),
    stringsAsFactors = FALSE))

  # types, as the release documents them
  ty <- DBI::dbGetQuery(con, paste0("DESCRIBE ", obis_h3_species_lookup_sql()))
  expect_equal(setNames(ty$column_type, ty$column_name)[c("aphiaid", "name_key", "lineage", "records")],
               c(aphiaid = "BIGINT", name_key = "INTEGER", lineage = "BIGINT[]", records = "BIGINT"))
  expect_equal(ty$column_name, vapply(SPECIES_LOOKUP_COLUMNS, `[[`, "", "name"))

  # no taxon table: the lineage is the aphiaid alone
  l0 <- DBI::dbGetQuery(con, paste0(
    "SELECT aphiaid::INTEGER AS a, lineage::VARCHAR AS l FROM (",
    obis_h3_species_lookup_sql(taxon = NULL), ") WHERE aphiaid IN (20, 41)"))
  expect_equal(l0$l, c("[20]", "[41]"))
})

test_that("obis_h3_species_sql(): cell x aphiaid x n per res, res 4 rolled up from the res-5 tier", {
  skip_species()
  con <- make_species_fixture()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, paste("CREATE TEMP TABLE species_lookup AS", obis_h3_species_lookup_sql()))

  get <- function(r) {
    x <- DBI::dbGetQuery(con, paste0(
      "SELECT h3, name_key, aphiaid::INTEGER AS aphiaid, n::INTEGER AS n, class
       FROM (", obis_h3_species_sql(r, lookup = "species_lookup"), ")"))
    x$cell <- cell_name(x$h3)
    x <- x[order(x$cell, x$aphiaid), c("cell", "name_key", "aphiaid", "n", "class")]
    rownames(x) <- NULL
    x
  }
  want5 <- data.frame(
    cell     = c(rep("P5", 4), rep("Q5", 3), rep("R5", 3), rep("S5", 2)),
    name_key = c(6L, 4L, 3L, 6L,  6L, 2L, 5L,  4L, 1L, 5L,  6L, 3L),
    aphiaid  = c(16L, 18L, 23L, 24L,  16L, 20L, 41L,  18L, 33L, 41L,  16L, 23L),
    n        = c(40L, 30L, 25L, 10L,  8L, 12L, 60L,  15L, 70L, 5L,  7L, 90L),
    class    = c("Mammalia", "Mammalia", "Aves", "Mammalia", "Mammalia", "Mammalia", NA,
                 "Mammalia", "Florideophyceae", NA, "Mammalia", "Aves"),
    stringsAsFactors = FALSE)
  expect_equal(get(5), want5)

  # res 4: P and Q merge (16: 40 + 8); R and S as at res 5
  want4 <- data.frame(
    cell     = c(rep("PQ4", 6), rep("R4", 3), rep("S4", 2)),
    name_key = c(6L, 4L, 2L, 3L, 6L, 5L,  4L, 1L, 5L,  6L, 3L),
    aphiaid  = c(16L, 18L, 20L, 23L, 24L, 41L,  18L, 33L, 41L,  16L, 23L),
    n        = c(48L, 30L, 12L, 25L, 10L, 60L,  15L, 70L, 5L,  7L, 90L),
    class    = c("Mammalia", "Mammalia", "Mammalia", "Aves", "Mammalia", NA,
                 "Mammalia", "Florideophyceae", NA, "Mammalia", "Aves"),
    stringsAsFactors = FALSE)
  expect_equal(get(4), want4)
  # res 3 reads the res-3 tier directly: the same rows on the res-3 parents
  w3 <- want4; w3$cell <- sub("4$", "3", w3$cell)
  expect_equal(get(3), w3)
  expect_false(grepl("h3_cell_to_parent", obis_h3_species_sql(3)))
  expect_true(grepl("res = 5", obis_h3_species_sql(4)))

  # per decade: records with a year only (S's 7 untimed records drop out)
  d5 <- DBI::dbGetQuery(con, paste0(
    "SELECT decade, h3, aphiaid::INTEGER AS aphiaid, n::INTEGER AS n FROM (",
    obis_h3_species_sql(5, lookup = "species_lookup", decade = TRUE), ")"))
  expect_equal(sum(d5$n), 372L - 7L)
  expect_setequal(unique(d5$decade), c(2000L, 2010L))
  expect_equal(d5$n[d5$decade == 2000 & cell_name(d5$h3) == "R5" & d5$aphiaid == 18], 15L)
  d2010 <- DBI::dbGetQuery(con, paste0(
    "SELECT * FROM (", obis_h3_species_sql(5, lookup = "species_lookup", decade = TRUE,
                                           decades = 2010), ")"))
  expect_equal(unique(d2010$decade), 2010L)
})

test_that("obis_h3_year_sql(): indicators per year, all taxa and per EOV", {
  skip_species()
  con <- make_species_fixture()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  get <- function(...) {
    x <- DBI::dbGetQuery(con, paste0(
      "SELECT * EXCLUDE (cell_id) FROM (", obis_h3_year_sql(...), ")"))
    x$cell <- cell_name(x$h3)
    x <- x[order(x$year, x$cell), ]
    rownames(x) <- NULL
    x
  }
  y5 <- get(5)
  expect_equal(y5[, c("year", "cell")], data.frame(
    year = c(2005L, 2009L, 2009L, 2009L, 2015L, 2015L, 2015L),
    cell = c("R5", "P5", "Q5", "R5", "P5", "Q5", "S5"), stringsAsFactors = FALSE))
  expect_equal(as.numeric(y5$n),  c(20, 55, 8, 70, 50, 72, 90))
  # Tursiops truncatus is one name on two aphiaids: P5 2015 is one species of 50 records
  expect_equal(as.numeric(y5$sp), c(2, 2, 1, 1, 1, 2, 1))
  expect_equal(y5$shannon, c(-(0.75 * log(0.75) + 0.25 * log(0.25)),
                             -(30 / 55 * log(30 / 55) + 25 / 55 * log(25 / 55)),
                             0, 0, 0, -(12 / 72 * log(12 / 72) + 60 / 72 * log(60 / 72)), 0),
               tolerance = 1e-12)
  # ES(50) of Q5 2015 (12 + 60 records) is 2 - 4e-8
  expect_equal(y5$es, c(NA, 2, NA, 1, 1, 2, 1), tolerance = 1e-6)
  expect_true(all(y5$res == 5))

  # res 4 from the res-5 tier: P and Q merge
  y4 <- get(4)
  expect_equal(y4$cell, c("R4", "PQ4", "R4", "PQ4", "S4"))
  expect_equal(as.numeric(y4$n),  c(20, 63, 70, 122, 90))
  expect_equal(as.numeric(y4$sp), c(2, 3, 1, 3, 1))

  # per EOV (the cetacean aphiaids), and a years filter
  e4 <- get(4, eov = TRUE)
  expect_equal(unique(e4$eov), "marineMammals")
  expect_equal(e4$year, c(2005L, 2009L, 2015L))
  expect_equal(as.numeric(e4$n),  c(15, 38, 62))
  expect_equal(as.numeric(e4$sp), c(1, 2, 2))
  expect_equal(get(5, years = 2009)$cell, c("P5", "Q5", "R5"))

  # the decade SQL is the same builder, by decade
  d <- DBI::dbGetQuery(con, paste0(
    "SELECT decade, SUM(n)::INTEGER AS n FROM (",
    .obis_h3_period_sql(5, "decade"), ") GROUP BY 1 ORDER BY 1"))
  expect_equal(d$decade, c(2000L, 2010L))
  expect_equal(d$n, c(20L + 55L + 8L + 70L, 50L + 72L + 90L))
})

test_that("obis_h3_species_heads(): Animalia and the taxa spanning two or more named classes", {
  skip_species()
  con <- make_species_fixture()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, paste("CREATE TEMP TABLE species_lookup AS", obis_h3_species_lookup_sql()))

  h <- obis_h3_species_heads(con)
  expect_equal(h, data.frame(
    aphiaid   = c(1, 2, 10),
    name      = c("Biota", "Animalia", "Chordata"),
    rank      = c("Superdomain", "Kingdom", "Phylum"),
    n_classes = c(3L, 2L, 2L),   # Pikaia's NULL class is not counted
    n_species = c(7L, 6L, 6L),
    records   = c(372, 302, 302),
    reason    = c("multi_class", "included", "multi_class"),
    stringsAsFactors = FALSE))
  # Animalia stays listed even when it spans one class
  h3c <- obis_h3_species_heads(con, min_classes = 3L)
  expect_equal(h3c$aphiaid, c(1, 2))
  expect_equal(h3c$reason, c("multi_class", "included"))
  # without taxon names
  expect_true(all(is.na(obis_h3_species_heads(con, taxon = NULL)$name)))
})

test_that("obis_h3_write_partitions(): one sorted data_0.parquet per partition, _none for NULL", {
  skip_species()
  con <- make_species_fixture()
  dir <- tempfile("parts_")
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(dir, recursive = TRUE) }, add = TRUE)
  DBI::dbExecute(con, paste("CREATE TEMP TABLE species_lookup AS", obis_h3_species_lookup_sql()))
  sql <- obis_h3_species_sql(5, lookup = "species_lookup")

  w <- obis_h3_write_partitions(con, sql, dir)
  expect_equal(w$class, c("Aves", "Florideophyceae", "Mammalia", NA))
  expect_equal(w$path, paste0("class=", c("Aves", "Florideophyceae", "Mammalia", "_none"),
                              "/data_0.parquet"))
  expect_equal(w$rows, c(2, 1, 7, 2))
  # exactly one file per partition, nothing else
  expect_setequal(list.files(dir, recursive = TRUE), w$path)

  # the files hold exactly the query's rows (the partition key decoded from the path)
  rd <- glue::glue("read_parquet('{dir}/*/*.parquet', hive_partitioning = true,
                    hive_types = {{'class': 'VARCHAR'}})")
  got  <- DBI::dbGetQuery(con, glue::glue(
    "SELECT h3, name_key, aphiaid::INTEGER AS aphiaid, n::INTEGER AS n,
            NULLIF(class, '_none') AS class FROM {rd} ORDER BY ALL"))
  want <- DBI::dbGetQuery(con, glue::glue(
    "SELECT h3, name_key, aphiaid::INTEGER AS aphiaid, n::INTEGER AS n, class
     FROM ({sql}) ORDER BY ALL"))
  expect_equal(got, want)
  ty <- DBI::dbGetQuery(con, glue::glue("DESCRIBE SELECT * FROM read_parquet('{dir}/class=Mammalia/data_0.parquet', hive_partitioning = false)"))
  expect_equal(paste(ty$column_name, ty$column_type),
               paste(vapply(SPECIES_COLUMNS, `[[`, "", "name"), vapply(SPECIES_COLUMNS, `[[`, "", "type")))

  # sorted by cell_id, aphiaid in every file
  srt <- DBI::dbGetQuery(con, glue::glue("
    SELECT filename, COUNT(*) FILTER (WHERE k < lag_k) AS out_of_order
    FROM (SELECT filename, (cell_id::HUGEINT * 100000 + aphiaid) AS k,
                 lag((cell_id::HUGEINT * 100000 + aphiaid)) OVER (PARTITION BY filename ORDER BY file_row_number) AS lag_k
          FROM read_parquet('{dir}/*/*.parquet', filename = true, file_row_number = true))
    GROUP BY 1"))
  expect_equal(nrow(srt), 4L)
  expect_true(all(srt$out_of_order == 0))

  # two partition levels, and a value that needs encoding
  DBI::dbExecute(con, "UPDATE species_lookup SET class = 'Aves incertae/sedis' WHERE class = 'Aves'")
  w2 <- obis_h3_write_partitions(
    con, obis_h3_species_sql(5, lookup = "species_lookup", decade = TRUE),
    file.path(dir, "dec"), partition_by = c("decade", "class"))
  expect_true("decade=2010/class=Aves%20incertae%2Fsedis/data_0.parquet" %in% w2$path)
  expect_true("decade=2010/class=_none/data_0.parquet" %in% w2$path)
  back <- DBI::dbGetQuery(con, glue::glue(
    "SELECT DISTINCT decade, class FROM read_parquet('{dir}/dec/*/*/*.parquet', hive_partitioning = true,
       hive_types = {{'decade': 'INTEGER', 'class': 'VARCHAR'}}) WHERE class LIKE 'Aves%'"))
  expect_equal(back$class, rep("Aves incertae/sedis", nrow(back)))

  # a real value equal to the NULL spelling is refused
  DBI::dbExecute(con, "UPDATE species_lookup SET class = '_none' WHERE class = 'Mammalia'")
  expect_error(obis_h3_write_partitions(con, sql, file.path(dir, "x")), "null_value")
})

test_that("export: year and species layers, release.json, and the Animalia subtree matches h3t's SQL", {
  skip_species()
  con <- make_species_fixture()
  dir <- tempfile("export_")
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(dir, recursive = TRUE) }, add = TRUE)

  files <- obis_h3_export_parquet(con, dir, "v20261022", res_decade = 1:2, res_year = 3:5,
                                  res_species = 3:5, species_decades = TRUE, verbose = FALSE)
  out <- file.path(dir, "v20261022")
  expect_true(all(file.exists(files)))
  expect_true(all(file.exists(file.path(out, c("collection.json", "species/heads.json",
                                               "species/species.parquet")))))

  # year layers: one partition per year present, at the res asked for
  yd <- list.dirs(file.path(out, "year", "all"), recursive = FALSE, full.names = FALSE)
  expect_equal(yd, c("year=2005", "year=2009", "year=2015"))
  expect_setequal(list.files(file.path(out, "year/all/year=2009")), paste0("res=", 3:5))
  y <- DBI::dbGetQuery(con, glue::glue(
    "SELECT n::DOUBLE AS n, sp::DOUBLE AS sp FROM read_parquet('{out}/year/all/year=2015/res=4/data_0.parquet')
     ORDER BY n"))
  expect_equal(y$n, c(90, 122))
  expect_equal(y$sp, c(1, 3))
  ye <- DBI::dbGetQuery(con, glue::glue(
    "SELECT n::DOUBLE AS n FROM read_parquet('{out}/year/eov/eov=marineMammals/year=2009/res=4/data_0.parquet')"))
  expect_equal(ye$n, 38)

  # species: one file per (res, class), the lookup and the heads
  for (r in 3:5)
    expect_setequal(list.files(file.path(out, "species", paste0("res=", r))),
                    paste0("class=", c("Aves", "Florideophyceae", "Mammalia", "_none")))
  expect_true(all(file.exists(file.path(out, "species/res=4", paste0(
    "class=", c("Aves", "Florideophyceae", "Mammalia", "_none")), "data_0.parquet"))))
  expect_true(dir.exists(file.path(out, "species_decade/res=5/decade=2000/class=_none")))
  lk <- DBI::dbGetQuery(con, glue::glue("SELECT * FROM read_parquet('{out}/species/species.parquet')"))
  expect_equal(nrow(lk), 7L)
  expect_equal(names(lk), vapply(SPECIES_LOOKUP_COLUMNS, `[[`, "", "name"))
  hj <- jsonlite::read_json(file.path(out, "species/heads.json"))
  expect_false(hj$built)
  expect_equal(hj$n, 3L)
  expect_equal(vapply(hj$heads, function(h) h$aphiaid, 0), c(1, 2, 10))

  # files.parquet: rows per year and species file; the lookup is its own layer
  mf <- DBI::dbGetQuery(con, glue::glue("SELECT * FROM read_parquet('{out}/files.parquet')"))
  expect_equal(sum(mf$layer == "year_all"), 3L * 3L)     # 3 years x res 3:5, all present
  expect_equal(sum(mf$rows[mf$layer == "year_all" & grepl("res=5", mf$path)]), 7)
  expect_equal(sum(mf$layer == "species"), 3L * 4L)
  expect_equal(sum(mf$rows[mf$layer == "species" & grepl("^species/res=5/", mf$path)]), 12)
  expect_equal(mf$rows[mf$layer == "species_lookup"], 7)
  expect_true(all(c("year_eov", "species_decade") %in% mf$layer))

  # stats: year rows, one per year x res x variable for year_all
  st <- DBI::dbGetQuery(con, glue::glue("SELECT * FROM read_parquet('{out}/stats.parquet')"))
  expect_equal(nrow(dplyr::distinct(st, layer, key, rank, decade, year, res, variable)), nrow(st))
  expect_equal(sum(st$layer == "year_all"), 3L * 3L * 5L)
  expect_false(any(st$layer %in% c("species", "species_decade")))
  expect_equal(st$max[st$layer == "year_all" & st$year == 2015 & st$res == 4 & st$variable == "n"], 122)

  # release.json: the year keys and the species layer in the h3:species_table shape
  js <- jsonlite::read_json(file.path(out, "release.json"))
  expect_true(all(c("year_all", "year_eov", "species", "species_decade") %in% names(js$layers)))
  expect_equal(unlist(js$years), c(2005L, 2009L, 2015L))
  expect_equal(unlist(js$year_range), c(2005L, 2015L))
  expect_true(nzchar(js$year_note))
  sp <- js$layers$species
  expect_equal(sp$href_template, "species/res={res}/class={class}/data_0.parquet")
  expect_equal(unlist(sp$resolutions), 3:5)
  expect_equal(unlist(sp$partition_by), "class")
  expect_equal(unlist(sp$sorted_by), c("cell_id", "aphiaid"))
  expect_equal(sp$columns, list(cell = "cell_id", species = "aphiaid", count = "n"))
  expect_equal(sp$lookup$href, "species/species.parquet")
  expect_equal(sp$lookup$lineage_column, "lineage")
  expect_equal(sp$heads$href, "species/heads.json")
  expect_equal(sp$rows, 12 + 11 + 11)
  expect_equal(vapply(sp$by_res, function(b) b$rows, 0), c(11, 11, 12))
  expect_equal(js$layers$year_all$rows, 7 + 5 + 5)

  # the Animalia subtree from the species files equals .h3t_indicators_sql() over
  # occ_h3 filtered by the recursive taxon CTE (as obis_h3t_sql(aphiaid = 2))
  for (r in 3:5) {
    tier <- .obis_tier(r)
    ref_src <- glue::glue("
      SELECT CAST(h3_cell_to_parent(cell_id, {r}) AS BIGINT) AS cell_id, species, SUM(records) AS ni
      FROM occ_h3
      WHERE res = {tier} AND aphiaid IN (SELECT taxonID FROM taxon_tree)
      GROUP BY 1, 2")
    ref <- DBI::dbGetQuery(con, glue::glue("
      WITH RECURSIVE {.h3t_taxon_tree_cte(2)}
      SELECT lower(printf('%x', cell_id)) AS h3, n::DOUBLE AS n, sp::DOUBLE AS sp, shannon, simpson, es
      FROM ({.h3t_indicators_sql(ref_src)}) _r ORDER BY h3"))
    got <- DBI::dbGetQuery(con, glue::glue("
      SELECT h3, n::DOUBLE AS n, sp::DOUBLE AS sp, shannon, simpson, es
      FROM ({obis_h3_species_subtree_sql(out, 2, r)}) _g ORDER BY h3"))
    expect_equal(nrow(got), c(3L, 3L, 4L)[r - 2L])  # Corallina's cell R stays, for its animals
    expect_identical(got$h3, ref$h3)
    expect_identical(got$n, ref$n)
    expect_identical(got$sp, ref$sp)
    for (v in c("shannon", "simpson", "es")) {
      expect_identical(is.na(got[[v]]), is.na(ref[[v]]))
      expect_lt(max(abs(got[[v]] - ref[[v]]), 0, na.rm = TRUE), 1e-9)
    }
  }
  # Animalia at res 4 drops Corallina from R (n 90 -> 20) and counts Tursiops once in PQ
  a4 <- DBI::dbGetQuery(con, glue::glue(
    "SELECT h3, n::DOUBLE AS n, sp::DOUBLE AS sp FROM ({obis_h3_species_subtree_sql(out, 2, 4)})"))
  expect_equal(setNames(a4$n, cell_name(a4$h3))[c("PQ4", "R4", "S4")], c(PQ4 = 185, R4 = 20, S4 = 97))
  expect_equal(setNames(a4$sp, cell_name(a4$h3))[c("PQ4", "R4", "S4")], c(PQ4 = 5, R4 = 2, S4 = 2))
  # a class-bounded subtree reads its class file plus _none; Cetacea needs Mammalia only
  c4 <- DBI::dbGetQuery(con, glue::glue(
    "SELECT n::DOUBLE AS n FROM ({obis_h3_species_subtree_sql(out, 13, 4, classes = 'Mammalia')}) ORDER BY n"))
  expect_equal(c4$n, c(7, 15, 100))
  p4 <- DBI::dbGetQuery(con, glue::glue(
    "SELECT n::DOUBLE AS n FROM ({obis_h3_species_subtree_sql(out, 41, 4, classes = NA)}) ORDER BY n"))
  expect_equal(p4$n, c(5, 60))
})

test_that("export of a store without aphiaid or years skips the species and year layers", {
  skip_species()
  con <- DBI::dbConnect(duckdb::duckdb())
  dir <- tempfile("export_")
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(dir, recursive = TRUE) }, add = TRUE)
  DBI::dbExecute(con, "LOAD h3;")
  # the demo store's shape: species and records, no aphiaid, no ranks, no year
  DBI::dbExecute(con, "
    CREATE TABLE occ_h3 AS
    SELECT 3::UTINYINT AS res, CAST(h3_latlng_to_cell(10, -50, 3) AS BIGINT) AS cell_id,
           NULL::BIGINT AS aphiaid, NULL::VARCHAR AS phylum, NULL::VARCHAR AS class,
           NULL::VARCHAR AS \"order\", NULL::VARCHAR AS family, NULL::VARCHAR AS genus,
           'Gadus morhua' AS species, NULL::SMALLINT AS date_year, 5::BIGINT AS records")
  DBI::dbExecute(con, "CREATE TABLE idx_h3 AS
    SELECT 3::UTINYINT AS res, cell_id, 5::BIGINT AS n, 1::BIGINT AS sp, 0::DOUBLE AS shannon,
           1::DOUBLE AS simpson, NULL::DOUBLE AS es FROM occ_h3")
  expect_no_error(obis_h3_export_parquet(con, dir, "v0", res_decade = 3L, verbose = FALSE))
  js <- jsonlite::read_json(file.path(dir, "v0", "release.json"))
  expect_false(any(c("species", "year_all") %in% names(js$layers)))
  expect_length(js$years, 0)
  expect_false(dir.exists(file.path(dir, "v0", "species")))
  expect_true(file.exists(file.path(dir, "v0", "collection.json")))
})

# the h3 STAC profile of the Ocean Metrics catalog, when the platform repo is checked out
om_platform <- function() path.expand(Sys.getenv("OM_PLATFORM", "~/Github/oceanmetrics/platform"))
om_h3_schema <- function() file.path(om_platform(), "packages/catalog/schemas/h3.schema.json")

test_that("obis_h3_stac_collection() validates against the h3 profile (jsonvalidate, ajv)", {
  skip_species()
  skip_if_not_installed("jsonvalidate")
  skip_if_not(file.exists(om_h3_schema()), "oceanmetrics/platform h3 schema not found")
  skip_if_not_installed("V8")
  con <- make_species_fixture()
  dir <- tempfile("export_")
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(dir, recursive = TRUE) }, add = TRUE)
  obis_h3_export_parquet(con, dir, "v20261022", res_decade = 1:2, res_year = 3:4,
                         res_species = 3:5, verbose = FALSE)
  out <- file.path(dir, "v20261022")
  f   <- file.path(out, "collection.json")

  v  <- jsonvalidate::json_validator(om_h3_schema(), engine = "ajv")
  ok <- v(f, verbose = TRUE)
  expect_true(ok, info = paste(capture.output(print(attr(ok, "errors"))), collapse = "\n"))

  cj <- jsonlite::read_json(f)
  expect_equal(cj$type, "Collection")
  expect_equal(unlist(cj$`h3:resolutions`), 1:7)
  expect_equal(cj$`h3:layout`$template, "all/res={res}/data_0.parquet")
  expect_equal(cj$`h3:species_table`$href_template, "species/res={res}/class={class}/data_0.parquet")
  expect_equal(cj$`h3:species_table`$lookup$key, "aphiaid")
  expect_equal(cj$`obis:layers`$year_all$template, "year/all/year={year}/res={res}/data_0.parquet")
  expect_equal(unlist(cj$`obis:layers`$year_all$`h3:periods`$values), c("2005", "2009", "2015"))
  expect_equal(cj$`obis:species`$heads$href, "species/heads.json")
  expect_equal(unlist(cj$extent$temporal$interval[[1]]),
               c("2005-01-01T00:00:00Z", "2026-10-22T00:00:00Z"))

  # the schema is strict about h3:species_table: an unknown key there fails
  bad <- cj
  bad$`h3:species_table`$name_key <- "name_key"
  fb  <- tempfile(fileext = ".json")
  jsonlite::write_json(bad, fb, auto_unbox = TRUE, null = "null")
  expect_false(v(fb))
})

test_that("obis_h3_stac_collection() passes om-catalog validate h3 (node CLI)", {
  skip_species()
  skip_on_cran()
  npx <- Sys.which("npx")
  skip_if(!nzchar(npx), "node (npx) not found")
  skip_if_not(file.exists(file.path(om_platform(), "packages/catalog/dist/cli.js")),
              "om-catalog not built in oceanmetrics/platform")
  con <- make_species_fixture()
  dir <- tempfile("export_")
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(dir, recursive = TRUE) }, add = TRUE)
  obis_h3_export_parquet(con, dir, "v20261022", res_decade = 1L, res_year = 3L,
                         res_species = 3:4, verbose = FALSE)
  f   <- file.path(dir, "v20261022", "collection.json")
  res <- suppressWarnings(system2(npx, c("--prefix", om_platform(), "om-catalog", "validate", "h3", f),
                                  stdout = TRUE, stderr = TRUE))
  expect_null(attr(res, "status"), info = paste(res, collapse = "\n"))
  expect_true(any(grepl("^ok ", res)), info = paste(res, collapse = "\n"))
})
