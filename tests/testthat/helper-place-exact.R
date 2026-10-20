# helpers shared by test-place-exact.R and the exact place layer of test-export-parquet.R

spatial_ext_ok <- function() {
  tryCatch({
    c0 <- DBI::dbConnect(duckdb::duckdb())
    on.exit(DBI::dbDisconnect(c0, shutdown = TRUE), add = TRUE)
    DBI::dbExecute(c0, "INSTALL spatial; LOAD spatial;")
    TRUE
  }, error = function(e) FALSE)
}

# lon/lat polygons ----
pe_poly <- function(xy) sf::st_polygon(list(rbind(xy, xy[1, ])))
pe_sf <- function(...) {
  p <- list(...)
  sf::st_sf(place_id = names(p), geometry = sf::st_sfc(p, crs = 4326))
}

# GeoParquet of places, geometry as WKB BLOB or DuckDB's native GEOMETRY, optional area_km2
pe_write_places <- function(file, places, geometry_type = c("blob", "geometry"), area = NULL) {
  geometry_type <- match.arg(geometry_type)
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "INSTALL spatial; LOAD spatial;")
  df <- data.frame(place_id = places$place_id,
                   wkb = sf::st_as_binary(sf::st_geometry(places), hex = TRUE),
                   stringsAsFactors = FALSE)
  if (!is.null(area)) df$area_km2 <- area
  duckdb::duckdb_register(con, "pl", df)
  g <- if (geometry_type == "blob") "ST_AsWKB(ST_GeomFromHEXWKB(wkb))::BLOB" else "ST_GeomFromHEXWKB(wkb)"
  DBI::dbExecute(con, sprintf(
    "COPY (SELECT place_id, %s%s AS geometry FROM pl) TO '%s' (FORMAT PARQUET)",
    if (is.null(area)) "" else "area_km2, ", g, file))
  invisible(file)
}

