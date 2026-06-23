# Package index

## Read

Functions for reading data.

## Analyze

Functions for calculating indicators.

- [`calc_indicators()`](http://marinebon.org/obisindicators/reference/calc_indicators.md)
  : Calculate Biodiversity Indicators, including ES50 (Hurlbert index)

## H3 grid & tiles

Build an H3 grid, and serve indicators as H3 hexagon tiles.

- [`make_hex_res()`](http://marinebon.org/obisindicators/reference/make_hex_res.md)
  : Make hexagon feature
- [`build_obis_h3_duckdb()`](http://marinebon.org/obisindicators/reference/build_obis_h3_duckdb.md)
  : Build the OBIS H3 DuckDB store
- [`obis_h3t_sql()`](http://marinebon.org/obisindicators/reference/obis_h3t_sql.md)
  : Build an h3t tile SQL query for an OBIS biodiversity indicator
- [`obis_h3t_url()`](http://marinebon.org/obisindicators/reference/obis_h3t_url.md)
  : Assemble an h3t tile (or stats) URL for an OBIS indicator

## Visualize

Functions for visualizing indicators.

- [`gmap_indicator()`](http://marinebon.org/obisindicators/reference/gmap_indicator.md)
  : Statically map indicators using ggplot

## Data

Locally available datasets for running examples.

- [`occ_1960s`](http://marinebon.org/obisindicators/reference/occ_1960s.md)
  : OBIS occurrences, temporal sample for the 1960s, limited to 1M
  records
- [`occ_1970s`](http://marinebon.org/obisindicators/reference/occ_1970s.md)
  : OBIS occurrences, temporal sample for the 1970s, limited to 1M
  records
- [`occ_1980s`](http://marinebon.org/obisindicators/reference/occ_1980s.md)
  : OBIS occurrences, temporal sample for the 1980s, limited to 1M
  records
- [`occ_1990s`](http://marinebon.org/obisindicators/reference/occ_1990s.md)
  : OBIS occurrences, temporal sample for the 1990s, limited to 1M
  records
- [`occ_1M`](http://marinebon.org/obisindicators/reference/occ_1M.md) :
  OBIS occurrences, global sample of 1 million records
- [`occ_2000s`](http://marinebon.org/obisindicators/reference/occ_2000s.md)
  : OBIS occurrences, temporal sample for the 2000s, limited to 1M
  records
- [`occ_2010s`](http://marinebon.org/obisindicators/reference/occ_2010s.md)
  : OBIS occurrences, temporal sample for the 2010s, limited to 1M
  records
- [`occ_SAtlantic`](http://marinebon.org/obisindicators/reference/occ_SAtlantic.md)
  : OBIS occurrences, South Atlantic full regional sample
- [`occ_fk`](http://marinebon.org/obisindicators/reference/occ_fk.md) :
  OBIS occurrences, Florida Keys full regional sample
