# Extracted from test-species-table.R:451

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
