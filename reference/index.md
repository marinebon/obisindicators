# Package index

## Read

Functions for reading data.

## Analyze

Functions for calculating indicators.

- [`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md)
  : Calculate Biodiversity Indicators, including ES50 (Hurlbert index)

## H3 grid & tiles

Build an H3 grid, and serve indicators as H3 hexagon tiles.

- [`make_hex_res()`](https://marinebon.org/obisindicators/reference/make_hex_res.md)
  : Make hexagon feature
- [`build_obis_h3_duckdb()`](https://marinebon.org/obisindicators/reference/build_obis_h3_duckdb.md)
  : Build the OBIS H3 DuckDB store
- [`obis_h3t_sql()`](https://marinebon.org/obisindicators/reference/obis_h3t_sql.md)
  : Build an h3t tile SQL query for an OBIS biodiversity indicator
- [`obis_h3t_url()`](https://marinebon.org/obisindicators/reference/obis_h3t_url.md)
  : Assemble an h3t tile (or stats) URL for an OBIS indicator

## Taxonomy & effort proxy

Resolve children taxa (any rank), close the WoRMS coverage gap from the
REST API, and the sightings-per-unit-effort (SPUE) proxy.

- [`calc_spue()`](https://marinebon.org/obisindicators/reference/calc_spue.md)
  : Sightings-per-unit-effort (SPUE) effort proxy, per H3 cell (R
  reference)

- [`obis_spue_sql()`](https://marinebon.org/obisindicators/reference/obis_spue_sql.md)
  : Build an h3t tile SQL query for the SPUE effort proxy

- [`obis_taxon_children()`](https://marinebon.org/obisindicators/reference/obis_taxon_children.md)
  : Resolve the descendant taxa of a WoRMS AphiaID

- [`obis_taxon_fill_gaps()`](https://marinebon.org/obisindicators/reference/obis_taxon_fill_gaps.md)
  :

  Fill gaps in the `taxon` table from the WoRMS REST API

- [`obis_taxon_orphans()`](https://marinebon.org/obisindicators/reference/obis_taxon_orphans.md)
  :

  AphiaIDs present in `occ_h3` but missing from the `taxon` table

- [`obis_taxon_subtree_sql()`](https://marinebon.org/obisindicators/reference/obis_taxon_subtree_sql.md)
  : Standalone SQL for the AphiaID subtree (descendant taxonIDs)

- [`wm_aphia_records()`](https://marinebon.org/obisindicators/reference/wm_aphia_records.md)
  : Look up WoRMS taxon records by AphiaID

## Essential Ocean Variables

GOOS/IOOS biology & ecosystems EOVs as WoRMS AphiaID subtrees, per the
IOOS Marine Life Data Network definitions.

- [`obis_eov_aphiaid()`](https://marinebon.org/obisindicators/reference/obis_eov_aphiaid.md)
  : AphiaID seeds for one or more EOVs
- [`obis_eov_bake()`](https://marinebon.org/obisindicators/reference/obis_eov_bake.md)
  : Bake the EOV membership and precomputed-indicator layers into a
  store
- [`obis_eov_seeds()`](https://marinebon.org/obisindicators/reference/obis_eov_seeds.md)
  : Essential Ocean Variable (EOV) taxonomic seeds
- [`obis_eov_sql()`](https://marinebon.org/obisindicators/reference/obis_eov_sql.md)
  : Build an h3t tile SQL query for an Essential Ocean Variable

## Visualize

Functions for visualizing indicators.

- [`gmap_indicator()`](https://marinebon.org/obisindicators/reference/gmap_indicator.md)
  : Statically map indicators using ggplot
- [`make_hex_res()`](https://marinebon.org/obisindicators/reference/make_hex_res.md)
  : Make hexagon feature

## Data

Locally available datasets for running examples.

- [`occ_1960s`](https://marinebon.org/obisindicators/reference/occ_1960s.md)
  : OBIS occurrences, temporal sample for the 1960s, limited to 1M
  records
- [`occ_1970s`](https://marinebon.org/obisindicators/reference/occ_1970s.md)
  : OBIS occurrences, temporal sample for the 1970s, limited to 1M
  records
- [`occ_1980s`](https://marinebon.org/obisindicators/reference/occ_1980s.md)
  : OBIS occurrences, temporal sample for the 1980s, limited to 1M
  records
- [`occ_1990s`](https://marinebon.org/obisindicators/reference/occ_1990s.md)
  : OBIS occurrences, temporal sample for the 1990s, limited to 1M
  records
- [`occ_1M`](https://marinebon.org/obisindicators/reference/occ_1M.md) :
  OBIS occurrences, global sample of 1 million records
- [`occ_2000s`](https://marinebon.org/obisindicators/reference/occ_2000s.md)
  : OBIS occurrences, temporal sample for the 2000s, limited to 1M
  records
- [`occ_2010s`](https://marinebon.org/obisindicators/reference/occ_2010s.md)
  : OBIS occurrences, temporal sample for the 2010s, limited to 1M
  records
- [`occ_SAtlantic`](https://marinebon.org/obisindicators/reference/occ_SAtlantic.md)
  : OBIS occurrences, South Atlantic full regional sample
- [`occ_fk`](https://marinebon.org/obisindicators/reference/occ_fk.md) :
  OBIS occurrences, Florida Keys full regional sample
