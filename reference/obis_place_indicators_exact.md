# Exact point-in-polygon indicators per place

Computes the biodiversity indicators of each place of a polygon
collection (EEZs, offshore regions, sanctuaries, ...) from the OBIS
occurrences that fall **inside the polygon**, tested point by point with
DuckDB's spatial extension, with no H3 approximation. This complements
[`obis_place_indicators()`](https://marinebon.org/obisindicators/reference/obis_place_indicators.md),
which pools area-weighted H3 cells.

## Usage

``` r
obis_place_indicators_exact(
  occ,
  places,
  eov = NULL,
  decades = TRUE,
  years = TRUE,
  esn = 50L,
  species = TRUE,
  lookup = NULL,
  max_vertices = 256L,
  con = NULL,
  memory_limit = NULL,
  threads = NULL,
  temp_dir = NULL,
  max_temp_dir_size = NULL,
  s3_region = "us-east-1",
  s3_anonymous = TRUE,
  verbose = FALSE,
  grid_deg = NULL
)
```

## Arguments

- occ:

  the occurrences: a `data.frame` with `decimalLongitude`,
  `decimalLatitude`, `species` and optionally `date_year`, `records` and
  `aphiaid` (needed for `eov`), or parquet path(s)/glob(s) of OBIS open
  data (`s3://` URLs too), either the nested layout (DwC fields in an
  `interpreted` struct) or flat. The schema is probed from one file.

- places:

  the places: an `sf` object, or the path(s) of GeoParquet file(s), with
  a `place_id` column and polygon geometry (WKB `geometry`), e.g. a
  gazetteer `places.parquet`. An optional `area_km2` column is used for
  `density`; without it the geodesic area is computed from the geometry
  (`ST_Area_Spheroid`). `place_id` must be unique.

- eov:

  EOV membership for the `eov` rows: `NULL` (none), a data frame with
  columns `eov` and `taxonID` (matched to `aphiaid`), or a `DBI`
  connection to a store with an `eov` table (see
  [`obis_eov_bake()`](https://marinebon.org/obisindicators/reference/obis_eov_bake.md)).

- decades:

  decades (first year) to compute besides all years: `TRUE` (default)
  for 1960-2020 as in the export, `FALSE` or `NULL` for none, or an
  integer vector.

- years:

  per-year rows: `TRUE` (default) every year with records, `FALSE` or
  `NULL` none, or an integer vector of years.

- esn:

  expected sample size for ES(n); default 50.

- species:

  also return the species of each place (default TRUE): one row per
  place x aphiaid x name with its records and first and last year, from
  the same point-in-polygon pass, so the Place page lists exact species
  rather than those of the H3 cells it overlaps.

- lookup:

  optional species lookup giving `name_key` (the release's
  `species/species.parquet`, as a path, or a data frame with `species`
  and `name_key`): a place's species name gets the lookup's `name_key`,
  so the rows join the release lookup; a name the lookup lacks gets a
  key above its largest. Without it, `name_key` is a dense rank of the
  names in the result.

- max_vertices:

  the most vertices a polygon piece may have before it is cut into
  quadrants (default 256, at least 8). It only affects speed and memory,
  not results.

- con:

  optional DuckDB connection to use (the `spatial` extension is loaded
  into it); default a private in-memory one. Temporary tables are
  dropped on exit.

- memory_limit, threads, temp_dir, max_temp_dir_size:

  DuckDB resource guards, as in
  [`build_obis_h3_duckdb()`](https://marinebon.org/obisindicators/reference/build_obis_h3_duckdb.md).
  Pass them for a global parquet scan, which otherwise can exhaust RAM.

- s3_region, s3_anonymous:

  for `s3://` sources, as in
  [`build_obis_h3_duckdb()`](https://marinebon.org/obisindicators/reference/build_obis_h3_duckdb.md).

- verbose:

  message progress.

- grid_deg:

  deprecated and ignored (the polygons used to be clipped to a grid); a
  message is shown when it is given.

## Value

a list with

- `indicators`: one row per place x `eov` (`"all"` or the EOV) x
  `decade` (NA = all years) with records: `place_id`, `eov`, `decade`,
  `n` (records), `sp` (species), `shannon`, `simpson` (sum of p^2), `es`
  (ES(`esn`), NA where `n < esn`), `hill_1` (`exp(shannon)`), `hill_2`
  (`1 / simpson`), `bp` (Berger-Parker, `max(ni) / n`, the `maxp` of
  [`calc_indicators()`](https://marinebon.org/obisindicators/reference/calc_indicators.md))
  and `density` (`n / area_km2`, records per km2).

- `years`: the same per place x `eov` x `year`.

- `species` (with `species = TRUE`): one row per place x `aphiaid` x
  `name_key` with records: `place_id`, `aphiaid`, `name_key` (one per
  species name: a place's distinct `name_key` count is its `sp`), `n`
  (records; they sum to the place's all-taxa `n`), `year_min`,
  `year_max` (NA when no record has a year), ordered by place and
  records, most first.

- `diagnostics`: `records_in` (records summed over the places, all taxa
  and years), `records_out` (filtered records outside every place),
  `records_total` (filtered records), `records_in_unique`
  (`records_total - records_out`, `records_in` without double counting
  overlaps), `overlaps` (a list: `n` locations that match more than one
  place, their `place_ids` and `records`), `n_places`,
  `n_places_with_records`, `n_locations` (distinct locations),
  `n_pieces`, `max_vertices`, `max_piece_vertices` (the largest piece)
  and `subdivision_rounds`.

Without overlapping places, `records_in + records_out == records_total`.

## Details

The method:

1.  **Occurrence filters** as
    [`build_obis_h3_duckdb()`](https://marinebon.org/obisindicators/reference/build_obis_h3_duckdb.md):
    `species`, `decimalLatitude` and `decimalLongitude` not null;
    `dropped` and `absence` not true. Records are grouped by (longitude,
    latitude, `aphiaid`, `species`, year), `records` being the row count
    (or the sum of a `records` column when the source has one).

2.  **Place pieces**: each polygon is dumped into its parts (so a place
    split at +/-180 becomes local parts with local bounding boxes), and
    every part with more than `max_vertices` vertices is cut into the
    four quadrants of its own bounding box (`ST_Intersection`, empties
    dropped, parts dumped again), round after round until every piece is
    small. The spatial join then tests points against small pieces
    instead of rings with hundreds of thousands of vertices. Each round
    is a table (so DuckDB can spill) and copies a geometry at most four
    times; at most 24 rounds, else an error.

3.  **Join**: each distinct location is matched to the pieces with
    `ST_Intersects` (DuckDB's R-tree spatial join) and then to its
    `place_id`. A location on the shared boundary of two places matches
    both; these are counted in `diagnostics$overlaps` and warned about.

4.  **Indicators** per place, by EOV (`"all"` plus each EOV in `eov`)
    and by decade (all years, then each of `decades`) or by year, with
    the shared indicator SQL (the ES(`esn`) term of the parity contract
    is untouched).

Polygons must be valid (no self-intersections); a point exactly on a
polygon edge counts as inside.

## Examples

``` r
if (FALSE) { # \dontrun{
res <- obis_place_indicators_exact(
  "/data/obis/occurrence/*.parquet", "~/data/places/mr_eez/places.parquet",
  eov = obis_store_connect("~/data/obis/obis_h3.duckdb"),
  memory_limit = "16GB", threads = 6, temp_dir = "/data/tmp")
obis_place_exact_write(res, "~/data/obis-h3/v20261020", "mr_eez")
} # }
```
