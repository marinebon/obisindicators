# shared synthetic fixture for the taxon-children and SPUE parity tests: a
# small WoRMS-like `taxon` tree (Infraorder Cetacea subtree + an unrelated
# bird) and a species-level `occ_h3`. Needs the duckdb h3 community extension.

h3_ext_ok <- function() {
  tryCatch({
    c0 <- DBI::dbConnect(duckdb::duckdb())
    on.exit(DBI::dbDisconnect(c0, shutdown = TRUE), add = TRUE)
    DBI::dbExecute(c0, "INSTALL h3 FROM community; LOAD h3;")
    TRUE
  }, error = function(e) FALSE)
}

# returns list(con, db); caller disconnects + unlinks
make_taxon_fixture <- function() {
  db  <- tempfile(fileext = ".duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db, read_only = FALSE)
  DBI::dbExecute(con, "LOAD h3;")

  # taxon tree: Infraorder Cetacea (1000) subtree + unrelated bird (2000).
  # acceptedNameUsageID = taxonID (all accepted). ranks span Infraorder..Species
  # so the recursive walk must cross arbitrary intermediate ranks.
  DBI::dbExecute(con, "
    CREATE TABLE taxon (
      taxonID BIGINT, parentNameUsageID BIGINT, acceptedNameUsageID BIGINT,
      scientificName VARCHAR, taxonRank VARCHAR);")
  DBI::dbExecute(con, "
    INSERT INTO taxon VALUES
      (1000, NULL, 1000, 'Cetacea',               'Infraorder'),
      (1100, 1000, 1100, 'Delphinidae',           'Family'),
      (1101, 1000, 1101, 'Balaenopteridae',       'Family'),
      (1110, 1100, 1110, 'Tursiops',              'Genus'),
      (1111, 1110, 1111, 'Tursiops truncatus',    'Species'),
      (1112, 1100, 1112, 'Delphinus delphis',     'Species'),
      (1120, 1101, 1120, 'Balaenoptera',          'Genus'),
      (1121, 1120, 1121, 'Balaenoptera musculus', 'Species'),
      (2000, NULL, 2000, 'Aves',                  'Class'),
      (2001, 2000, 2001, 'Larus argentatus',      'Species');")

  # occ_h3 at res 7: real H3 cells from lat/lng. three cetacean cells + one bird
  # cell. cell_id is BIGINT (> 2^53) so always compare on the hex string. Cell D
  # has cetacean effort (Balaenoptera) but NO Tursiops truncatus, so a
  # SPUE(target = T. truncatus) there must read 0, not NULL.
  DBI::dbExecute(con, "
    CREATE TABLE occ_h3 AS
    SELECT res, CAST(h3_latlng_to_cell(lat, lng, 7) AS BIGINT) AS cell_id,
           aphiaid, species, records
    FROM (VALUES
      (7, 10.0, -50.0, 1111, 'Tursiops truncatus',    30),
      (7, 10.0, -50.0, 1112, 'Delphinus delphis',     20),
      (7, 10.0, -50.0, 1121, 'Balaenoptera musculus', 10),
      (7, 11.0, -51.0, 1111, 'Tursiops truncatus',     5),
      (7, 11.0, -51.0, 1121, 'Balaenoptera musculus', 15),
      (7, 12.0, -52.0, 1121, 'Balaenoptera musculus', 40),
      (7, 40.0,  60.0, 2001, 'Larus argentatus',      100)
    ) AS t(res, lat, lng, aphiaid, species, records);")

  list(con = con, db = db)
}
