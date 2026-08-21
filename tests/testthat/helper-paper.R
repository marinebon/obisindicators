# fixture for the analysis-side helpers (store/scale/compare/temporal/place):
# the EOV fixture's taxon tree + occ_h3, extended with DwC rank columns and
# years, plus the precomputed idx_h3 and idx_h3_eov layers. Needs the duckdb h3
# community extension.
#
# cells (res 7, real H3 from lat/lng):
#   A (10.0,-50.0): Chelonia mydas 120 (2015) + Caretta caretta 80 (1975)  = 200
#   B (res-7 sibling of A: same res-6 parent, so A+B merge at res <= 6):
#                   Chelonia mydas 45 (2015)                                =  45
#   C (20.0,-60.0): Caretta caretta 200 (1975) + Chelonia mydas 60 (2015)   = 260
#   D (40.0, 60.0): Larus argentatus 300 (2015)                            = 300
# C and D stay distinct at every resolution.
make_paper_fixture <- function() {
  db  <- tempfile(fileext = ".duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db, read_only = FALSE)
  DBI::dbExecute(con, "LOAD h3;")

  # B's coordinates: the centroid of a res-7 sibling of A (shared res-6 parent)
  a7  <- h3::geo_to_h3(data.frame(lat = 10, lng = -50), res = 7)
  b7  <- setdiff(h3::h3_to_children(h3::h3_to_parent(a7, 6), 7), a7)[1]
  bll <- h3::h3_to_geo(b7)

  DBI::dbExecute(con, "
    CREATE TABLE taxon (
      taxonID BIGINT, parentNameUsageID BIGINT, acceptedNameUsageID BIGINT,
      scientificName VARCHAR, taxonRank VARCHAR, taxonomicStatus VARCHAR);")
  DBI::dbExecute(con, "
    INSERT INTO taxon VALUES
      (2689,   NULL,   2689,   'Testudines',        'Order',       'accepted'),
      (987094, 2689,   987094, 'Chelonioidea',      'Superfamily', 'accepted'),
      (987095, 987094, 987095, 'Cheloniidae',       'Family',      'accepted'),
      (987096, 987095, 987096, 'Chelonia',          'Genus',       'accepted'),
      (987097, 987096, 987097, 'Chelonia mydas',    'Species',     'accepted'),
      (987098, 987095, 987098, 'Caretta caretta',   'Species',     'accepted'),
      (1836,   NULL,   1836,   'Aves',              'Class',       'accepted'),
      (1840,   1836,   1840,   'Larus argentatus',  'Species',     'accepted');")

  # OBIS files turtles under class Reptilia / order Testudines; a user filtering
  # class = 'Testudines' (wrong rank) must get nothing by rank column.
  DBI::dbExecute(con, sprintf("
    CREATE TABLE occ_h3_base AS
    SELECT CAST(h3_latlng_to_cell(lat, lng, 7) AS BIGINT) AS cell_id,
           aphiaid, phylum, class, \"order\", family, genus, species, date_year, records
    FROM (VALUES
      (10.0, -50.0, 987097, 'Chordata', 'Reptilia', 'Testudines', 'Cheloniidae', 'Chelonia', 'Chelonia mydas',    2015, 120),
      (10.0, -50.0, 987098, 'Chordata', 'Reptilia', 'Testudines', 'Cheloniidae', 'Caretta',  'Caretta caretta',   1975,  80),
      (%.8f, %.8f, 987097, 'Chordata', 'Reptilia', 'Testudines', 'Cheloniidae', 'Chelonia', 'Chelonia mydas',    2015,  45),
      (20.0, -60.0, 987098, 'Chordata', 'Reptilia', 'Testudines', 'Cheloniidae', 'Caretta',  'Caretta caretta',   1975, 200),
      (20.0, -60.0, 987097, 'Chordata', 'Reptilia', 'Testudines', 'Cheloniidae', 'Chelonia', 'Chelonia mydas',    2015,  60),
      (40.0,  60.0, 1840,   'Chordata', 'Aves',     'Charadriiformes', 'Laridae', 'Larus',  'Larus argentatus',  2015, 300)
    ) AS t(lat, lng, aphiaid, phylum, class, \"order\", family, genus, species, date_year, records);",
    bll[1, "lat"], bll[1, "lng"]))
  DBI::dbExecute(con, "
    CREATE TABLE occ_h3 (
      res UTINYINT, cell_id BIGINT, aphiaid BIGINT,
      phylum VARCHAR, class VARCHAR, \"order\" VARCHAR, family VARCHAR,
      genus VARCHAR, species VARCHAR, date_year SMALLINT, records BIGINT);")
  for (r in c(3L, 5L, 7L))
    DBI::dbExecute(con, sprintf("
      INSERT INTO occ_h3
      SELECT %d AS res, CAST(h3_cell_to_parent(cell_id, %d) AS BIGINT) AS cell_id,
             aphiaid, phylum, class, \"order\", family, genus, species, date_year,
             SUM(records) AS records
      FROM occ_h3_base GROUP BY ALL;", r, r))
  DBI::dbExecute(con, "DROP TABLE occ_h3_base;")

  # precomputed all-taxa layer, exactly as the build does it
  DBI::dbExecute(con, "
    CREATE TABLE idx_h3 (
      res UTINYINT, cell_id BIGINT, n BIGINT, sp BIGINT,
      shannon DOUBLE, simpson DOUBLE, es DOUBLE);")
  for (r in 1:7) DBI::dbExecute(con, obisindicators:::.h3t_idx_sql(r, 50L))

  obis_eov_bake(con, eov = c("seaTurtles", "seabirds"), verbose = FALSE)
  list(con = con, db = db)
}

# the res-7 hex strings of the fixture's four points
paper_fixture_cells <- function(con) {
  a7 <- h3::geo_to_h3(data.frame(lat = 10, lng = -50), res = 7)
  b7 <- setdiff(h3::h3_to_children(h3::h3_to_parent(a7, 6), 7), a7)[1]
  data.frame(
    cell = c(a7, b7,
             h3::geo_to_h3(data.frame(lat = 20, lng = -60), res = 7),
             h3::geo_to_h3(data.frame(lat = 40, lng =  60), res = 7)),
    name = c("A", "B", "C", "D"), stringsAsFactors = FALSE)
}
