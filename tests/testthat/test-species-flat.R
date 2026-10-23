# 0.12.0: species_flat per resolution (res 1 and 2 rolled up from res 3) and split by
# res-1 parent, the lookup's eov, the split lineage file, and the amendment of a built
# release, on the synthetic store of helper-species.R plus a few res-3 rows that merge.

skip_flat <- function() {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("jsonlite")
  skip_if_not_installed("h3")
  skip_if_not(h3_ext_ok(), "duckdb h3 community extension unavailable")
}

flat_platform <- function() path.expand(Sys.getenv("OM_PLATFORM", "~/Github/oceanmetrics/platform"))

# three res-3 cells under one res-1 parent (two under one res-2 parent), with a species
# in all three, NULL years mixed with years, and one species whose years are all NULL:
#   c1: 16 2001 n 3, 16 NULL n 2, 18 1999 n 4, 33 NULL n 6
#   c2 (c1's res-2 sibling): 16 2010 n 5, 23 NULL n 1, 33 NULL n 1
#   c3 (another res-2 parent): 16 2020 n 1, 23 1995 n 2
merge_cells <- function() {
  a1 <- h3::geo_to_h3(data.frame(lat = -30, lng = 100), res = 1)
  k2 <- sort(h3::h3_to_children(a1, 2))
  c12 <- sort(h3::h3_to_children(k2[1], 3))
  list(A1 = a1, c1 = c12[1], c2 = c12[2], c3 = sort(h3::h3_to_children(k2[2], 3))[1],
       B2 = k2[1], C2 = k2[2])
}

add_merge_rows <- function(con) {
  m <- merge_cells()
  id <- function(h) sprintf("CAST(h3_string_to_h3('%s') AS BIGINT)", h)
  DBI::dbExecute(con, glue::glue("
    INSERT INTO occ_h3 (res, cell_id, aphiaid, phylum, class, \"order\", family, genus, species, date_year, records)
    SELECT 3, cell, aphiaid, phylum, class, ord, family, genus, species, yr::SMALLINT, n FROM (VALUES
      ({id(m$c1)}, 16, 'Chordata', 'Mammalia', 'Cetartiodactyla', 'Delphinidae', 'Tursiops', 'Tursiops truncatus', 2001, 3),
      ({id(m$c1)}, 16, 'Chordata', 'Mammalia', 'Cetartiodactyla', 'Delphinidae', 'Tursiops', 'Tursiops truncatus', NULL, 2),
      ({id(m$c1)}, 18, 'Chordata', 'Mammalia', 'Cetartiodactyla', 'Delphinidae', 'Orcinus', 'Orcinus orca', 1999, 4),
      ({id(m$c1)}, 33, 'Rhodophyta', 'Florideophyceae', 'Corallinales', 'Corallinaceae', 'Corallina', 'Corallina officinalis', NULL, 6),
      ({id(m$c2)}, 16, 'Chordata', 'Mammalia', 'Cetartiodactyla', 'Delphinidae', 'Tursiops', 'Tursiops truncatus', 2010, 5),
      ({id(m$c2)}, 23, 'Chordata', 'Aves', 'Charadriiformes', 'Laridae', 'Larus', 'Larus argentatus', NULL, 1),
      ({id(m$c2)}, 33, 'Rhodophyta', 'Florideophyceae', 'Corallinales', 'Corallinaceae', 'Corallina', 'Corallina officinalis', NULL, 1),
      ({id(m$c3)}, 16, 'Chordata', 'Mammalia', 'Cetartiodactyla', 'Delphinidae', 'Tursiops', 'Tursiops truncatus', 2020, 1),
      ({id(m$c3)}, 23, 'Chordata', 'Aves', 'Charadriiformes', 'Laridae', 'Larus', 'Larus argentatus', 1995, 2)
    ) t(cell, aphiaid, phylum, class, ord, family, genus, species, yr, n)"))
  m
}

# a species lookup temp table and the res-3 flat file, as the export writes them
write_flat3 <- function(con, dir) {
  DBI::dbExecute(con, glue::glue(
    "CREATE OR REPLACE TEMP TABLE lk AS {obis_h3_species_lookup_sql()}"))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  DBI::dbExecute(con, glue::glue(
    "COPY (SELECT h3, cell_id, name_key, aphiaid, n, year_min, year_max
           FROM ({obis_h3_species_sql(3, lookup = 'lk')}) _f ORDER BY cell_id, aphiaid)
     TO '{dir}/res=3.parquet' (FORMAT PARQUET);"))
  file.path(dir, "res=3.parquet")
}

rd <- function(con, sql) DBI::dbGetQuery(con, sql)

test_that("obis_h3_species_rollup_sql(): res 1 and 2 equal a direct aggregation of the store", {
  skip_flat()
  con <- make_species_fixture()
  dir <- file.path(tempfile("flat_"), "species_flat")
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(dirname(dir), recursive = TRUE) }, add = TRUE)
  m  <- add_merge_rows(con)
  f3 <- write_flat3(con, dir)
  cols <- "cell_id::DOUBLE AS cell_id, name_key, aphiaid::DOUBLE AS aphiaid, n::DOUBLE AS n, year_min, year_max"
  for (r in 1:2) {
    got <- rd(con, glue::glue("SELECT {cols} FROM ({obis_h3_species_rollup_sql(glue::glue(\"read_parquet('{f3}')\"), r)}) _g
                               ORDER BY cell_id, aphiaid"))
    ref <- rd(con, glue::glue("SELECT {cols} FROM ({obis_h3_species_sql(r, lookup = 'lk')}) _d ORDER BY cell_id, aphiaid"))
    expect_equal(got, ref)
    expect_gt(nrow(got), 0)
  }
  # the merged res-1 cell, species by species: n summed, the least first year and the greatest last
  a1 <- rd(con, glue::glue(
    "SELECT aphiaid::DOUBLE AS aphiaid, n::DOUBLE AS n, year_min, year_max
     FROM ({obis_h3_species_rollup_sql(glue::glue(\"read_parquet('{f3}')\"), 1)}) _g
     WHERE cell_id = h3_string_to_h3('{m$A1}') ORDER BY aphiaid"))
  expect_equal(a1$aphiaid, c(16, 18, 23, 33))
  expect_equal(a1$n, c(11, 4, 3, 7))
  expect_equal(a1$year_min, c(2001L, 1999L, 1995L, NA))  # a NULL year never wins; all NULL stays NULL
  expect_equal(a1$year_max, c(2020L, 1999L, 1995L, NA))
  # res 2: c1 and c2 merge, c3 alone
  b2 <- rd(con, glue::glue(
    "SELECT aphiaid::DOUBLE AS aphiaid, n::DOUBLE AS n, year_min, year_max
     FROM ({obis_h3_species_rollup_sql(glue::glue(\"read_parquet('{f3}')\"), 2)}) _g
     WHERE cell_id = h3_string_to_h3('{m$B2}') ORDER BY aphiaid"))
  expect_equal(b2$n, c(10, 4, 1, 7))
  expect_equal(b2$year_max, c(2010L, 1999L, NA, NA))
  expect_error(obis_h3_species_rollup_sql("t", 16))
})

test_that("obis_h3_write_species_flat(): roll-ups and the split by res-1 parent union to the whole", {
  skip_flat()
  con <- make_species_fixture()
  dir <- file.path(tempfile("flat_"), "species_flat")
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(dirname(dir), recursive = TRUE) }, add = TRUE)
  m  <- add_merge_rows(con)
  f3 <- write_flat3(con, dir)
  md5 <- tools::md5sum(f3)
  w  <- obis_h3_write_species_flat(con, dir, row_group_rows = 2048L, split_row_group_rows = 2048L)
  expect_equal(unname(tools::md5sum(f3)), unname(md5))  # the res-3 file is read, never rewritten
  n3 <- rd(con, glue::glue("SELECT COUNT(*)::DOUBLE AS n FROM read_parquet('{f3}')"))$n
  parents <- rd(con, glue::glue(
    "SELECT DISTINCT lower(printf('%x', h3_cell_to_parent(cell_id, 1))) AS p FROM read_parquet('{f3}') ORDER BY 1"))$p
  expect_true(m$A1 %in% parents)
  expect_equal(sort(w$path), sort(c("species_flat/res=1.parquet", "species_flat/res=2.parquet",
                                    paste0("species_flat/res=3/p=", parents, ".parquet"))))
  expect_equal(w$parent[w$res == 3], parents)
  expect_true(all(is.na(w$parent[w$res < 3])))
  expect_equal(sum(w$rows[w$res == 3]), n3)
  expect_equal(w$bytes, as.numeric(file.size(file.path(dirname(dir), w$path))))

  # every new file: the columns without h3, sorted by cell_id then aphiaid
  for (f in file.path(dirname(dir), w$path)) {
    d <- rd(con, glue::glue(
      "SELECT *, (cell_id < lag(cell_id) OVER o OR (cell_id = lag(cell_id) OVER o AND aphiaid <= lag(aphiaid) OVER o)) AS bad
       FROM read_parquet('{f}', file_row_number = true, hive_partitioning = false) WINDOW o AS (ORDER BY file_row_number)"))
    expect_equal(setdiff(names(d), c("file_row_number", "bad")), SPECIES_FLAT_COLUMNS, info = f)
    expect_false(any(d$bad, na.rm = TRUE), info = f)
  }
  # a split file holds the res-3 cells of its parent only
  for (p in parents) {
    pp <- rd(con, glue::glue(
      "SELECT DISTINCT lower(printf('%x', h3_cell_to_parent(cell_id, 1))) AS p, h3_get_resolution(cell_id) AS r
       FROM read_parquet('{dir}/res=3/p={p}.parquet', hive_partitioning = false)"))
    expect_equal(pp$p, p)
    expect_equal(unique(pp$r), 3L)
  }
  # the split files union to res=3.parquet (without h3), row for row
  u <- rd(con, glue::glue("
    WITH a AS (SELECT cell_id, name_key, aphiaid, n, year_min, year_max FROM read_parquet('{f3}')),
         b AS (SELECT * FROM read_parquet('{dir}/res=3/*.parquet', hive_partitioning = false))
    SELECT (SELECT COUNT(*) FROM (SELECT * FROM a EXCEPT ALL SELECT * FROM b))::DOUBLE AS only_whole,
           (SELECT COUNT(*) FROM (SELECT * FROM b EXCEPT ALL SELECT * FROM a))::DOUBLE AS only_split,
           (SELECT COUNT(*) FROM b)::DOUBLE AS n_split"))
  expect_equal(u$only_whole, 0)
  expect_equal(u$only_split, 0)
  expect_equal(u$n_split, n3)
  # the res-1 file sums the res-3 rows (records kept)
  t1 <- rd(con, glue::glue("SELECT SUM(n)::DOUBLE AS n FROM read_parquet('{dir}/res=1.parquet')"))$n
  t3 <- rd(con, glue::glue("SELECT SUM(n)::DOUBLE AS n FROM read_parquet('{f3}')"))$n
  expect_equal(t1, t3)

  # bad arguments
  expect_error(obis_h3_write_species_flat(con, dir, res = 3L), "coarser")
  expect_error(obis_h3_write_species_flat(con, dir, res = 1L, split = c("2" = 1L)), "split")
  expect_error(obis_h3_write_species_flat(con, dir, res = 1L, split = c("3" = 3L)), "parent")
  expect_error(obis_h3_write_species_flat(con, tempfile(), res = 1L), "no ")
})

test_that("obis_h3_write_species_flat(): small row groups with ascending cell_id statistics", {
  skip_flat()
  con <- DBI::dbConnect(duckdb::duckdb())
  dir <- tempfile("flat_rg_")
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(dir, recursive = TRUE) }, add = TRUE)
  DBI::dbExecute(con, "LOAD h3;")
  dir.create(dir)
  # 6,000 rows under one res-1 parent: 40 of its 49 res-3 cells x 150 species
  a1 <- h3::geo_to_h3(data.frame(lat = 10, lng = 10), res = 1)
  c3 <- sort(h3::h3_to_children(a1, 3))[1:40]
  DBI::dbExecute(con, glue::glue("
    COPY (SELECT lower(printf('%x', c)) AS h3, c AS cell_id, (s % 50)::INTEGER AS name_key, s::BIGINT AS aphiaid,
                 1::BIGINT AS n, 2000::SMALLINT AS year_min, 2001::SMALLINT AS year_max
          FROM (SELECT CAST(h3_string_to_h3(unnest([{paste0(\"'\", c3, \"'\", collapse = ', ')}])) AS BIGINT) AS c),
               range(150) t(s) ORDER BY cell_id, aphiaid)
    TO '{dir}/res=3.parquet' (FORMAT PARQUET);"))
  w <- obis_h3_write_species_flat(con, dir, res = 1L, split_row_group_rows = 2048L)
  f <- file.path(dir, "res=3", paste0("p=", a1, ".parquet"))
  expect_true(file.exists(f))
  g <- rd(con, glue::glue("
    SELECT row_group_id, row_group_num_rows::DOUBLE AS rows, stats_min_value::BIGINT AS mn, stats_max_value::BIGINT AS mx
    FROM parquet_metadata('{f}') WHERE path_in_schema = 'cell_id' ORDER BY row_group_id"))
  expect_equal(nrow(g), 3L)              # 6,000 rows in groups of 2,048
  expect_equal(sum(g$rows), 6000)
  expect_true(all(g$rows <= 2048))
  expect_false(anyNA(g$mn))               # statistics on cell_id
  expect_true(all(g$mn[-1] >= g$mx[-nrow(g)]))  # ascending: a cell's rows are in one group or two adjacent ones
})

test_that("obis_h3_write_species_lookup(): eov as the EOV layers count it, and the lineage file", {
  skip_flat()
  con <- make_species_fixture()
  dir <- tempfile("lookup_")
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(dir, recursive = TRUE) }, add = TRUE)
  DBI::dbExecute(con, glue::glue("CREATE OR REPLACE TEMP TABLE lk AS {obis_h3_species_lookup_sql()}"))
  w  <- obis_h3_write_species_lookup(con, "lk", dir)
  expect_equal(w$path, c(file.path(basename(dir), "species.parquet"), file.path(basename(dir), "lineage.parquet")))
  expect_equal(w$rows, c(7, 7))
  sp <- rd(con, glue::glue("SELECT * FROM read_parquet('{dir}/species.parquet', file_row_number = true) ORDER BY file_row_number"))
  expect_equal(setdiff(names(sp), "file_row_number"), c(vapply(SPECIES_LOOKUP_COLUMNS, `[[`, "", "name"), "eov"))
  expect_equal(sp$aphiaid, c(16, 18, 20, 23, 24, 33, 41))
  expect_equal(sp$eov, c("marineMammals", "marineMammals", "marineMammals", NA, "marineMammals", NA, NA))
  # the rule is the EOV layers' own join: occ_h3.aphiaid = eov.taxonID
  inl <- rd(con, "SELECT DISTINCT o.aphiaid::DOUBLE AS aphiaid, e.eov FROM occ_h3 o JOIN eov e ON o.aphiaid = e.taxonID ORDER BY 1")
  expect_equal(sp$aphiaid[!is.na(sp$eov)], inl$aphiaid)
  expect_equal(sp$eov[!is.na(sp$eov)], inl$eov)
  expect_equal(attr(w, "eov")$n, 4)
  # lineage.parquet: aphiaid, name_key, lineage only, the lookup's rows sorted by aphiaid
  ln <- rd(con, glue::glue("SELECT * FROM read_parquet('{dir}/lineage.parquet', file_row_number = true) ORDER BY file_row_number"))
  expect_equal(setdiff(names(ln), "file_row_number"), c("aphiaid", "name_key", "lineage"))
  ref <- rd(con, "SELECT aphiaid, name_key, lineage FROM lk ORDER BY aphiaid")
  expect_equal(ln$aphiaid, ref$aphiaid)
  expect_equal(ln$name_key, ref$name_key)
  expect_equal(ln$lineage, ref$lineage)
  expect_equal(ln$lineage[[1]], c(16, 15, 14, 13, 11, 10, 2, 1))
  # rewritten in place from its own file: the same rows in the same order (idempotent)
  before <- sp
  obis_h3_write_species_lookup(con, glue::glue("read_parquet('{dir}/species.parquet')"), dir)
  again <- rd(con, glue::glue("SELECT * FROM read_parquet('{dir}/species.parquet', file_row_number = true) ORDER BY file_row_number"))
  expect_equal(again, before)
  expect_false(any(file.exists(file.path(dir, c("species.parquet.tmp", "lineage.parquet.tmp")))))
  # no eov table: no eov column (not a column of NULLs)
  obis_h3_write_species_lookup(con, "lk", dir, eov = NULL)
  expect_false("eov" %in% names(rd(con, glue::glue("SELECT * FROM read_parquet('{dir}/species.parquet') LIMIT 1"))))
  # an aphiaid in two EOVs is refused, not picked
  DBI::dbExecute(con, "INSERT INTO eov VALUES ('seabirds', 16)")
  expect_error(obis_h3_write_species_lookup(con, "lk", dir), "more than one EOV")
  # one row per aphiaid
  DBI::dbExecute(con, "CREATE TEMP TABLE lk2 AS SELECT * FROM lk UNION ALL SELECT * FROM lk WHERE aphiaid = 16")
  expect_error(obis_h3_write_species_lookup(con, "lk2", dir, eov = NULL), "one row per aphiaid")
})

test_that("export: species_flat res 1-3 and the split, the lookup's eov, lineage.parquet, the collection", {
  skip_flat()
  con <- make_species_fixture()
  dir <- tempfile("export_")
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(dir, recursive = TRUE) }, add = TRUE)
  add_merge_rows(con)
  obis_h3_export_parquet(con, dir, "v20261101", res_decade = 1L, res_year = 3L, res_species = 3:4,
                         verbose = FALSE)
  out <- file.path(dir, "v20261101")
  fl  <- list.files(file.path(out, "species_flat"), recursive = TRUE)
  expect_true(all(c("res=1.parquet", "res=2.parquet", "res=3.parquet") %in% fl))
  expect_true(any(grepl("^res=3/p=[0-9a-f]{15}\\.parquet$", fl)))
  # res=1 straight from the store's aggregation
  got <- rd(con, glue::glue("SELECT cell_id::DOUBLE AS c, aphiaid::DOUBLE AS a, n::DOUBLE AS n, year_min, year_max
                             FROM read_parquet('{out}/species_flat/res=1.parquet') ORDER BY 1, 2"))
  ref <- rd(con, glue::glue("SELECT cell_id::DOUBLE AS c, aphiaid::DOUBLE AS a, n::DOUBLE AS n, year_min, year_max
                             FROM ({obis_h3_species_sql(1)}) _d ORDER BY 1, 2"))
  expect_equal(got, ref)
  js <- jsonlite::read_json(file.path(out, "release.json"))
  sf <- js$layers$species_flat
  expect_equal(unlist(sf$resolutions), 1:3)
  expect_equal(sf$template_parent, "species_flat/res=<res>/p=<parent>.parquet")
  expect_equal(sf$parent_res, list(`3` = 1L))
  expect_equal(sf$split_row_group_rows, 2048L)
  expect_equal(sf$split[[1]]$rows, sf$by_res[[3]]$rows)
  expect_equal(vapply(js$layers$species$lookup_columns, `[[`, "", "name")[11], "eov")
  expect_equal(js$layers$species$lineage$href, "species/lineage.parquet")
  mf <- rd(con, glue::glue("SELECT * FROM read_parquet('{out}/files.parquet')"))
  expect_equal(mf$layer[mf$path == "species/lineage.parquet"], "species_lineage")
  sp <- mf[grepl("^species_flat/res=3/p=", mf$path), ]
  expect_equal(sp$parent, sub(".*p=([0-9a-f]+)\\.parquet$", "\\1", sp$path))
  # the collection: obis:species.flat at res 1-3 with the split; h3:species_table unchanged
  cj <- jsonlite::read_json(file.path(out, "collection.json"))
  fj <- cj$`obis:species`$flat
  expect_equal(fj$href_template, "species_flat/res={res}.parquet")
  expect_equal(unlist(fj$resolutions), 1:3)
  expect_equal(fj$parent_template, "species_flat/res={res}/p={parent}.parquet")
  expect_equal(fj$parent_res, list(`3` = 1L))
  expect_equal(unlist(fj$file_columns$parent), SPECIES_FLAT_COLUMNS)
  expect_equal(cj$`h3:species_table`$href_template, "species/res={res}/class={class}/data_0.parquet")
  expect_equal(cj$`obis:species`$lineage$href, "species/lineage.parquet")
  expect_equal(cj$assets$species_lineage$href, "./species/lineage.parquet")
  expect_equal(cj$assets$species_flat_res1$href, "./species_flat/res=1.parquet")
  expect_equal(cj$`obis:layers`$species_flat$parent_template, "species_flat/res={res}/p={parent}.parquet")
  # the stable copy makes the flat and lineage hrefs absolute
  fs <- obis_h3_stac_stable(out, "https://example.org/obis-h3/v20261101/", file = file.path(dir, "collection.json"))
  sj <- jsonlite::read_json(fs)
  expect_equal(sj$`obis:species`$flat$parent_template,
               "https://example.org/obis-h3/v20261101/species_flat/res={res}/p={parent}.parquet")
  expect_equal(sj$`obis:species`$lineage$href, "https://example.org/obis-h3/v20261101/species/lineage.parquet")
  # the h3 profile 1.1 (node CLI of oceanmetrics/platform, when built)
  node <- Sys.which("node")
  cli  <- file.path(flat_platform(), "packages/catalog/dist/cli.js")
  skip_if(!nzchar(node) || !file.exists(cli), "om-catalog CLI not available")
  for (x in c(file.path(out, "collection.json"), fs)) {
    r <- suppressWarnings(system2(node, c(cli, "validate", "h3", x), stdout = TRUE, stderr = TRUE))
    expect_null(attr(r, "status"), info = paste(r, collapse = "\n"))
    expect_true(any(grepl("^ok ", r)), info = paste(r, collapse = "\n"))
  }
})

test_that("obis_h3_amend_species(): a 0.11 release gains the files, the rest unchanged", {
  skip_flat()
  con <- make_species_fixture()
  dir <- tempfile("amend_")
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); unlink(dir, recursive = TRUE) }, add = TRUE)
  m <- add_merge_rows(con)
  # a 0.11-shaped release: res-3 flat only, the lookup without eov, no lineage file
  obis_h3_export_parquet(con, dir, "v20261012", res_decade = 1L, res_year = 3L, res_species = 3:4,
                         res_species_flat = 3L, species_flat_split = NULL, verbose = FALSE)
  rel <- file.path(dir, "v20261012")
  obis_h3_write_species_lookup(con, glue::glue("read_parquet('{rel}/species/species.parquet')"),
                               file.path(rel, "species"), eov = NULL, row_group_rows = 100000L)
  unlink(file.path(rel, "species", "lineage.parquet"))
  DBI::dbExecute(con, glue::glue(
    "COPY (SELECT * FROM read_parquet('{rel}/files.parquet') WHERE path <> 'species/lineage.parquet')
     TO '{rel}/files.parquet.0' (FORMAT PARQUET)"))
  file.rename(file.path(rel, "files.parquet.0"), file.path(rel, "files.parquet"))
  js0 <- jsonlite::read_json(file.path(rel, "release.json"))
  js0$layers$species$lineage <- NULL
  js0$layers$species$lookup_columns <- js0$layers$species$lookup_columns[1:10]
  jsonlite::write_json(js0, file.path(rel, "release.json"), auto_unbox = TRUE, pretty = TRUE, digits = NA, null = "null")
  lk0  <- rd(con, glue::glue("SELECT * FROM read_parquet('{rel}/species/species.parquet', file_row_number = true) ORDER BY file_row_number"))
  mf0  <- rd(con, glue::glue("SELECT * FROM read_parquet('{rel}/files.parquet')"))
  keep <- setdiff(list.files(rel, recursive = TRUE),
                  c("species/species.parquet", "release.json", "files.parquet", "collection.json"))
  md5  <- tools::md5sum(file.path(rel, keep))

  w <- obis_h3_amend_species(con, rel)
  # every other file byte for byte
  expect_equal(unname(tools::md5sum(file.path(rel, keep))), unname(md5))
  # the lookup: the same rows in the same order, plus eov
  lk1 <- rd(con, glue::glue("SELECT * FROM read_parquet('{rel}/species/species.parquet', file_row_number = true) ORDER BY file_row_number"))
  expect_equal(lk1[, names(lk0)], lk0)
  expect_equal(setdiff(names(lk1), names(lk0)), "eov")
  expect_true(file.exists(file.path(rel, "species/lineage.parquet")))
  expect_true(all(c("species/species.parquet", "species/lineage.parquet", "species_flat/res=1.parquet",
                    "species_flat/res=2.parquet") %in% w$path))
  # the roll-up on the release equals the store's direct aggregation, at the merged cell too
  for (r in 1:2) {
    got <- rd(con, glue::glue("SELECT cell_id::DOUBLE AS c, aphiaid::DOUBLE AS a, n::DOUBLE AS n, year_min, year_max
                               FROM read_parquet('{rel}/species_flat/res={r}.parquet') ORDER BY 1, 2"))
    ref <- rd(con, glue::glue("SELECT cell_id::DOUBLE AS c, aphiaid::DOUBLE AS a, n::DOUBLE AS n, year_min, year_max
                               FROM ({obis_h3_species_sql(r)}) _d ORDER BY 1, 2"))
    expect_equal(got, ref)
  }
  # release.json and the manifest
  js <- jsonlite::read_json(file.path(rel, "release.json"))
  expect_equal(unlist(js$layers$species_flat$resolutions), 1:3)
  expect_equal(js$layers$species_flat$parent_res, list(`3` = 1L))
  expect_equal(js$layers$species$lineage$href, "species/lineage.parquet")
  expect_equal(vapply(js$layers$species$lookup_columns, `[[`, "", "name")[11], "eov")
  expect_equal(js$layers$species$eov$n$marineMammals, 4L)
  mf <- rd(con, glue::glue("SELECT * FROM read_parquet('{rel}/files.parquet')"))
  old <- mf0[mf0$path != "species/species.parquet", ]
  key <- function(d) do.call(paste, c(d[, c("layer", "path", "url_path", "rows", "bytes", "parent")], sep = "|"))
  expect_true(all(key(old) %in% key(mf)))   # every other row kept as it was
  expect_equal(mf$bytes[mf$path == "species/species.parquet"],
               as.numeric(file.size(file.path(rel, "species/species.parquet"))))
  expect_equal(nrow(mf), nrow(mf0) + 1L + sum(grepl("^species_flat/", w$path)))
  expect_equal(js$files$n_files, nrow(mf) + 1L)
  # the collection from the amended release.json is valid and lists the new files
  obis_h3_stac_collection(rel)
  cj <- jsonlite::read_json(file.path(rel, "collection.json"))
  expect_equal(unlist(cj$`obis:species`$flat$resolutions), 1:3)
  expect_equal(cj$`obis:species`$flat$parent_template, "species_flat/res={res}/p={parent}.parquet")
  expect_equal(cj$assets$species_lineage$href, "./species/lineage.parquet")
  # a second amendment changes nothing it already wrote
  md5b <- tools::md5sum(file.path(rel, c("species/species.parquet", "species_flat/res=1.parquet")))
  obis_h3_amend_species(con, rel)
  expect_equal(unname(tools::md5sum(file.path(rel, c("species/species.parquet", "species_flat/res=1.parquet")))),
               unname(md5b))
  expect_equal(nrow(rd(con, glue::glue("SELECT * FROM read_parquet('{rel}/files.parquet')"))), nrow(mf))
})
