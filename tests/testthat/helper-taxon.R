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

# fixture for the WoRMS gap-fill: a `taxon` table that is deliberately INCOMPLETE
# with respect to `occ_h3`, mimicking the real algae gap. occ_h3 carries three
# aphiaids absent from `taxon`:
#   3002 a species whose whole ancestor chain (3001 genus, 3000 class) is also
#        missing -> only a transitive-closure fill reconnects it;
#   1111 present in taxon already (control, must not be re-fetched);
#   9999 an id WoRMS has no record for -> must end up `unresolved`, not looping.
# returns list(con, db, worms) where `worms` is the stand-in WoRMS API table.
make_gapfill_fixture <- function() {
  db  <- tempfile(fileext = ".duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db, read_only = FALSE)

  DBI::dbExecute(con, "
    CREATE TABLE taxon (
      taxonID BIGINT, parentNameUsageID BIGINT, acceptedNameUsageID BIGINT,
      scientificName VARCHAR, taxonRank VARCHAR, taxonomicStatus VARCHAR);")
  DBI::dbExecute(con, "
    INSERT INTO taxon VALUES
      (1000, NULL, 1000, 'Cetacea',            'Infraorder', 'accepted'),
      (1100, 1000, 1100, 'Delphinidae',        'Family',     'accepted'),
      (1110, 1100, 1110, 'Tursiops',           'Genus',      'accepted'),
      (1111, 1110, 1111, 'Tursiops truncatus', 'Species',    'accepted');")

  # no h3 extension needed: cell_id values are arbitrary here, the gap-fill
  # never touches geometry
  DBI::dbExecute(con, "
    CREATE TABLE occ_h3 (res UTINYINT, cell_id BIGINT, aphiaid BIGINT,
                         species VARCHAR, records BIGINT);")
  DBI::dbExecute(con, "
    INSERT INTO occ_h3 VALUES
      (3, 11, 1111, 'Tursiops truncatus',  30),
      (3, 11, 3002, 'Navicula perminuta', 500),
      (3, 12, 3002, 'Navicula perminuta', 250),
      (3, 12, 9999, 'Deleted taxon',        7),
      -- same records rolled up at a finer tier: orphan counting must not
      -- double-count across resolution tiers
      (5, 21, 1111, 'Tursiops truncatus',  30),
      (5, 21, 3002, 'Navicula perminuta', 500),
      (5, 22, 3002, 'Navicula perminuta', 250),
      (5, 22, 9999, 'Deleted taxon',        7);")

  # what the stand-in WoRMS API knows. 9999 is deliberately absent.
  worms <- data.frame(
    taxonID             = c(3002L, 3001L, 3000L),
    parentNameUsageID   = c(3001L, 3000L, NA_integer_),
    acceptedNameUsageID = c(3002L, 3001L, 3000L),
    scientificName      = c("Navicula perminuta", "Navicula", "Bacillariophyceae"),
    taxonRank           = c("Species", "Genus", "Class"),
    taxonomicStatus     = rep("accepted", 3),
    stringsAsFactors    = FALSE)

  list(con = con, db = db, worms = worms)
}

# fixture for the EOV layer: a `taxon` tree rooted at two REAL EOV seed
# AphiaIDs (987094 Chelonioidea = seaTurtles, 1836 Aves = seabirds) with
# synthetic descendants, plus occ_h3 at real H3 cells. Record counts are well
# over esn=50 per cell so ES(50) is non-NULL and parity is actually exercised.
# Needs the duckdb h3 community extension.
make_eov_fixture <- function() {
  db  <- tempfile(fileext = ".duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db, read_only = FALSE)
  DBI::dbExecute(con, "LOAD h3;")

  DBI::dbExecute(con, "
    CREATE TABLE taxon (
      taxonID BIGINT, parentNameUsageID BIGINT, acceptedNameUsageID BIGINT,
      scientificName VARCHAR, taxonRank VARCHAR, taxonomicStatus VARCHAR);")
  DBI::dbExecute(con, "
    INSERT INTO taxon VALUES
      (987094, NULL,   987094, 'Chelonioidea',      'Superfamily', 'accepted'),
      (987095, 987094, 987095, 'Cheloniidae',       'Family',      'accepted'),
      (987096, 987095, 987096, 'Chelonia',          'Genus',       'accepted'),
      (987097, 987096, 987097, 'Chelonia mydas',    'Species',     'accepted'),
      (987098, 987095, 987098, 'Caretta caretta',   'Species',     'accepted'),
      (1836,   NULL,   1836,   'Aves',              'Class',       'accepted'),
      (1840,   1836,   1840,   'Larus argentatus',  'Species',     'accepted');")

  # two turtle cells (both with >= 50 records so ES(50) is defined) + a bird
  # cell that must NOT leak into the seaTurtles EOV. Rolled up to the same
  # resolution tiers the real store carries (H3T_RES_TIERS = 3/5/7) so the live
  # tile path — which selects a tier by zoom — has rows to read.
  DBI::dbExecute(con, "
    CREATE TABLE occ_h3_base AS
    SELECT CAST(h3_latlng_to_cell(lat, lng, 7) AS BIGINT) AS cell_id,
           aphiaid, species, records
    FROM (VALUES
      (10.0, -50.0, 987097, 'Chelonia mydas',   120),
      (10.0, -50.0, 987098, 'Caretta caretta',   80),
      (10.1, -50.1, 987097, 'Chelonia mydas',    45),
      (20.0, -60.0, 987098, 'Caretta caretta',  200),
      (20.0, -60.0, 987097, 'Chelonia mydas',    60),
      (40.0,  60.0, 1840,   'Larus argentatus', 300)
    ) AS t(lat, lng, aphiaid, species, records);")
  DBI::dbExecute(con, "
    CREATE TABLE occ_h3 (res UTINYINT, cell_id BIGINT, aphiaid BIGINT,
                         species VARCHAR, records BIGINT);")
  for (r in c(3L, 5L, 7L))
    DBI::dbExecute(con, sprintf("
      INSERT INTO occ_h3
      SELECT %d AS res, CAST(h3_cell_to_parent(cell_id, %d) AS BIGINT) AS cell_id,
             aphiaid, species, SUM(records) AS records
      FROM occ_h3_base GROUP BY 1, 2, 3, 4;", r, r))
  DBI::dbExecute(con, "DROP TABLE occ_h3_base;")

  list(con = con, db = db)
}

# a `fetch` stand-in for obis_taxon_fill_gaps(): serves only ids the fixture's
# WoRMS knows, and records each call so tests can assert the round structure
make_fetch_stub <- function(worms) {
  calls <- list()
  fn <- function(aphiaid) {
    ids <- as.integer(aphiaid)
    calls[[length(calls) + 1L]] <<- ids
    worms[worms$taxonID %in% ids, , drop = FALSE]
  }
  list(fn = fn, calls = function() calls)
}
