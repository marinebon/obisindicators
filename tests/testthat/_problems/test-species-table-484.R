# Extracted from test-species-table.R:484

# prequel ----------------------------------------------------------------------
skip_species <- function() {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("jsonlite")
  skip_if_not_installed("h3")
  skip_if_not(h3_ext_ok(), "duckdb h3 community extension unavailable")
}
cell_name <- function(h3, cl = species_fixture_cells()) {
  cl <- unlist(cl[setdiff(names(cl), "Q")])
  names(cl)[match(h3, cl)]
}
om_platform <- function() path.expand(Sys.getenv("OM_PLATFORM", "~/Github/oceanmetrics/platform"))
om_h3_schema <- function() file.path(om_platform(), "packages/catalog/schemas/h3.schema.json")

# test -------------------------------------------------------------------------
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
expect_match(jsonlite::read_json(om_h3_schema())$`$id`, "/h3/v1\\.1\\.0/")
v  <- jsonvalidate::json_validator(om_h3_schema(), engine = "ajv")
ok <- v(f, verbose = TRUE)
expect_true(ok, info = paste(capture.output(print(attr(ok, "errors"))), collapse = "\n"))
cj <- jsonlite::read_json(f)
expect_equal(cj$type, "Collection")
expect_equal(cj$id, "obis_h3")
expect_equal(cj$stac_extensions[[1]], "https://oceanmetrics.io/schemas/h3/v1.1.0/schema.json")
expect_equal(unlist(cj$`h3:resolutions`), 1:7)
expect_equal(cj$`h3:layout`$template, "all/res={res}/data_0.parquet")
expect_equal(cj$`h3:layout`$row_group_rows, 10240L)
ps <- cj$`h3:periods`
expect_length(ps, 2L)
expect_equal(vapply(ps, `[[`, "", "grain"), c("decade", "year"))
expect_equal(unlist(ps[[1]]$values), as.character(seq(1960, 2020, 10)))
expect_equal(unlist(ps[[1]]$resolutions), 1:2)
expect_equal(ps[[1]]$template, "decade/all/decade={decade}/res={res}/data_0.parquet")
expect_equal(unlist(ps[[2]]$values), c("2005", "2009", "2015"))
expect_equal(unlist(ps[[2]]$resolutions), 3:4)
expect_equal(ps[[2]]$template, "year/all/year={year}/res={res}/data_0.parquet")
st <- cj$`h3:species_table`
expect_equal(st$href_template, "species/res={res}/class={class}/data_0.parquet")
expect_equal(st$lookup$key, "aphiaid")
expect_equal(st$columns[c("year_min", "year_max", "period", "name_key")],
               list(year_min = "year_min", year_max = "year_max", period = "decade", name_key = "name_key"))
expect_equal(st$heads, "species/heads.json")
expect_equal(cj$`h3:heads`, list(layer = "taxon", href = "species/heads.json"))
expect_equal(names(cj$`cube:dimensions`), c("layer", "indicator", "period", "res"))
expect_equal(unlist(cj$`cube:dimensions`$layer$values), c("all", "marineMammals"))
expect_equal(unlist(cj$`cube:dimensions`$indicator$values), c("es", "sp", "shannon", "simpson", "n"))
pv <- unlist(cj$`cube:dimensions`$period$values)
expect_equal(pv[1:3], c("all", "1960s", "1970s"))
expect_true(all(c("2005", "2009", "2015") %in% pv))
expect_equal(cj$`atlas:metric`, "es")
expect_equal(names(cj$item_assets), c("data", "decade", "year"))
expect_true("legend" %in% unlist(cj$assets$stats$roles))
expect_true("search" %in% unlist(cj$assets$taxon_groups$roles))
expect_equal(cj$assets$species_flat_res3$href, "./species_flat/res=3.parquet")
il <- Filter(function(l) l$rel == "item", cj$links)
expect_equal(vapply(il, `[[`, "", "href"), c("./items/all.json", "./items/marineMammals.json"))
