# Connect to an obis_h3 DuckDB store

Opens a (by default read-only) DuckDB connection to a store produced by
[`build_obis_h3_duckdb()`](https://marinebon.org/obisindicators/reference/build_obis_h3_duckdb.md)
and loads the `h3` community extension, which every query in this
package needs (`h3_cell_to_parent`, `h3_h3_to_string`, ...).

## Usage

``` r
obis_store_connect(
  path = Sys.getenv("OBIS_H3_DUCKDB"),
  read_only = TRUE,
  install_h3 = TRUE
)
```

## Arguments

- path:

  path to the `.duckdb` file; defaults to the `OBIS_H3_DUCKDB`
  environment variable (set it once per machine, e.g. in `~/.Renviron`).

- read_only:

  open read-only (default TRUE; the analysis functions only read). Pass
  FALSE to bake layers (e.g.
  [`obis_eov_bake()`](https://marinebon.org/obisindicators/reference/obis_eov_bake.md)).

- install_h3:

  run `INSTALL h3 FROM community` before `LOAD h3` (needs network the
  first time; default TRUE).

## Value

a `DBI` connection. Disconnect with
`DBI::dbDisconnect(con, shutdown = TRUE)`.
