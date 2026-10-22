# fixture for the species x hex x count table and the year layers: an
# in-memory DuckDB with a WoRMS-like `taxon` tree and a dozen occ_h3 rows,
# rolled to the store's tiers (3/5/7), plus idx_h3 and a one-EOV `eov` table.
# Needs the duckdb h3 community extension and the h3 R package.
#
# taxon: 1 Biota > 2 Animalia > 10 Chordata > {11 Mammalia, 12 Aves, 41 Pikaia
# gracilens (no class)}; 11 > 13 Cetacea > 14 Delphinidae > {15 Tursiops > 16, 24
# (two aphiaids, one name: Tursiops truncatus), 17 Orcinus > 18 Orcinus orca,
# 19 Grampus > 20 Grampus orca (a synonym: accepted 18, its own parent 19)};
# 12 > 21 Laridae > 22 Larus > 23; 1 > 3 Plantae > 30 Rhodophyta > 31
# Florideophyceae > 32 Corallina > 33 Corallina officinalis.
#
# cells: P (10, -50); Q, a res-5 cell next to P's under the same res-4 parent
# (P and Q merge at res <= 4); R (20, -60); S (40, 60). years 2005, 2009, 2015
# (decades 2000, 2010) and one row with no year:
#   P: 16 Tursiops truncatus 2015 40, 24 Tursiops truncatus 2015 10,
#      18 Orcinus orca 2009 30, 23 Larus argentatus 2009 25
#   Q: 20 Grampus orca 2015 12, 16 Tursiops truncatus 2009 8,
#      41 Pikaia gracilens (class NULL) 2015 60
#   R: 33 Corallina officinalis 2009 70, 18 Orcinus orca 2005 15,
#      41 Pikaia gracilens 2005 5
#   S: 23 Larus argentatus 2015 90, 16 Tursiops truncatus (no year) 7
species_fixture_cells <- function() {
  p5 <- h3::geo_to_h3(data.frame(lat = 10, lng = -50), res = 5)
  p4 <- h3::h3_to_parent(p5, 4)
  q5 <- setdiff(h3::h3_to_children(p4, 5), p5)[1]
  r5 <- h3::geo_to_h3(data.frame(lat = 20, lng = -60), res = 5)
  s5 <- h3::geo_to_h3(data.frame(lat = 40, lng =  60), res = 5)
  list(P5 = p5, Q5 = q5, R5 = r5, S5 = s5,
       PQ4 = p4, R4 = h3::h3_to_parent(r5, 4), S4 = h3::h3_to_parent(s5, 4),
       PQ3 = h3::h3_to_parent(p5, 3), R3 = h3::h3_to_parent(r5, 3), S3 = h3::h3_to_parent(s5, 3),
       Q = h3::h3_to_geo(q5))
}

make_species_fixture <- function() {
  con <- DBI::dbConnect(duckdb::duckdb())
  DBI::dbExecute(con, "LOAD h3;")
  cl <- species_fixture_cells()

  DBI::dbExecute(con, "
    CREATE TABLE taxon (
      taxonID BIGINT, parentNameUsageID BIGINT, acceptedNameUsageID BIGINT,
      scientificName VARCHAR, taxonRank VARCHAR, taxonomicStatus VARCHAR);")
  DBI::dbExecute(con, "
    INSERT INTO taxon VALUES
      ( 1, NULL,  1, 'Biota',                 'Superdomain', 'accepted'),
      ( 2,    1,  2, 'Animalia',              'Kingdom',     'accepted'),
      ( 3,    1,  3, 'Plantae',               'Kingdom',     'accepted'),
      (10,    2, 10, 'Chordata',              'Phylum',      'accepted'),
      (11,   10, 11, 'Mammalia',              'Class',       'accepted'),
      (12,   10, 12, 'Aves',                  'Class',       'accepted'),
      (13,   11, 13, 'Cetacea',               'Infraorder',  'accepted'),
      (14,   13, 14, 'Delphinidae',           'Family',      'accepted'),
      (15,   14, 15, 'Tursiops',              'Genus',       'accepted'),
      (16,   15, 16, 'Tursiops truncatus',    'Species',     'accepted'),
      (24,   15, 24, 'Tursiops truncatus',    'Species',     'accepted'),
      (17,   14, 17, 'Orcinus',               'Genus',       'accepted'),
      (18,   17, 18, 'Orcinus orca',          'Species',     'accepted'),
      (19,   14, 19, 'Grampus',               'Genus',       'accepted'),
      (20,   19, 18, 'Grampus orca',          'Species',     'unaccepted'),
      (21,   12, 21, 'Laridae',               'Family',      'accepted'),
      (22,   21, 22, 'Larus',                 'Genus',       'accepted'),
      (23,   22, 23, 'Larus argentatus',      'Species',     'accepted'),
      (30,    3, 30, 'Rhodophyta',            'Phylum',      'accepted'),
      (31,   30, 31, 'Florideophyceae',       'Class',       'accepted'),
      (32,   31, 32, 'Corallina',             'Genus',       'accepted'),
      (33,   32, 33, 'Corallina officinalis', 'Species',     'accepted'),
      (41,   10, 41, 'Pikaia gracilens',      'Species',     'accepted');")

  DBI::dbExecute(con, sprintf("
    CREATE TABLE occ_h3_base AS
    SELECT CAST(h3_latlng_to_cell(lat, lng, 7) AS BIGINT) AS cell_id,
           aphiaid::BIGINT AS aphiaid, phylum, class, \"order\", family, genus, species,
           date_year::SMALLINT AS date_year, records::BIGINT AS records
    FROM (VALUES
      (10.0, -50.0, 16, 'Chordata', 'Mammalia', 'Cetartiodactyla', 'Delphinidae', 'Tursiops', 'Tursiops truncatus', 2015, 40),
      (10.0, -50.0, 24, 'Chordata', 'Mammalia', 'Cetartiodactyla', 'Delphinidae', 'Tursiops', 'Tursiops truncatus', 2015, 10),
      (10.0, -50.0, 18, 'Chordata', 'Mammalia', 'Cetartiodactyla', 'Delphinidae', 'Orcinus',  'Orcinus orca',       2009, 30),
      (10.0, -50.0, 23, 'Chordata', 'Aves', 'Charadriiformes', 'Laridae', 'Larus', 'Larus argentatus',         2009, 25),
      (%1$.8f, %2$.8f, 20, 'Chordata', 'Mammalia', 'Cetartiodactyla', 'Delphinidae', 'Grampus', 'Grampus orca', 2015, 12),
      (%1$.8f, %2$.8f, 16, 'Chordata', 'Mammalia', 'Cetartiodactyla', 'Delphinidae', 'Tursiops', 'Tursiops truncatus', 2009, 8),
      (%1$.8f, %2$.8f, 41, 'Chordata', NULL, NULL, NULL, 'Pikaia', 'Pikaia gracilens',                            2015, 60),
      (20.0, -60.0, 33, 'Rhodophyta', 'Florideophyceae', 'Corallinales', 'Corallinaceae', 'Corallina', 'Corallina officinalis', 2009, 70),
      (20.0, -60.0, 18, 'Chordata', 'Mammalia', 'Cetartiodactyla', 'Delphinidae', 'Orcinus',  'Orcinus orca',       2005, 15),
      (20.0, -60.0, 41, 'Chordata', NULL, NULL, NULL, 'Pikaia', 'Pikaia gracilens',                                2005,  5),
      (40.0,  60.0, 23, 'Chordata', 'Aves', 'Charadriiformes', 'Laridae', 'Larus', 'Larus argentatus',         2015, 90),
      (40.0,  60.0, 16, 'Chordata', 'Mammalia', 'Cetartiodactyla', 'Delphinidae', 'Tursiops', 'Tursiops truncatus', NULL, 7)
    ) AS t(lat, lng, aphiaid, phylum, class, \"order\", family, genus, species, date_year, records);",
    cl$Q[1, "lat"], cl$Q[1, "lng"]))
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

  DBI::dbExecute(con, "
    CREATE TABLE idx_h3 (
      res UTINYINT, cell_id BIGINT, n BIGINT, sp BIGINT,
      shannon DOUBLE, simpson DOUBLE, es DOUBLE);")
  for (r in 1:7) DBI::dbExecute(con, obisindicators:::.h3t_idx_sql(r, 50L))

  # one EOV, the four cetacean aphiaids (as obis_eov_bake() would expand Cetacea)
  DBI::dbExecute(con, "
    CREATE TABLE eov AS SELECT 'marineMammals' AS eov, taxonID::BIGINT AS taxonID
    FROM (VALUES (13), (14), (15), (16), (17), (18), (19), (20), (24)) t(taxonID);")
  con
}
