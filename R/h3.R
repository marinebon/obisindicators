fix_dateline <- function(geom){
  # geom = g

  xy <- st_coordinates(geom)
  x <- xy[,'X']
  y <- xy[,'Y']

  if (max(abs(diff(x))) < 300)
    return(geom)

  if (x[1] < 0){
    x[x > 0] <- x[x > 0] - 360
  } else {
    x[x < 0] <- x[x < 0] + 360
  }
  z <- try(suppressWarnings(
    tibble(
      x = x,
      y = y) %>%
      st_as_sf(coords = c("x", "y"), crs = 4326) %>%
      summarise(geometry = st_combine(geometry)) %>%
      st_cast("POLYGON") %>%
      #st_cast("MULTIPOLYGON") %>%
      pull(geometry) #%>%
      # st_make_valid() %>%
      #st_wrap_dateline() %>%
      # st_make_valid() %>%
      #st_union() # %>%
    # st_make_valid() %>%
  ))
  # mapview(z)

  if ("try-error" %in% class(z))
    browser()
  z
}

#' Make hexagon feature
#'
#' TODO: + sf feature or extent to minimize
#'
#' @param hex_res resolution of H3 hexagons; see [Table of Cell Areas for H3 Resolutions | H3](https://h3geo.org/docs/core-library/restable/)
#'
#' @return spatial feature `sf` object
#' @export
#' @import dplyr h3 purrr sf units
#'
#' @examples
make_hex_res <- function(hex_res = 2){
  # hex_res = 2

  # librarian::shelf(dplyr, h3, mapview, purrr, sf, units)

  # paths
  # hex     <- glue("abnj_hex_res{hex_res}")
  # hex_geo <- glue(here("data/{hex}.geojson"))
  # hex_shp <- glue(here("data/{hex}_shp/{hex}.shp"))
  # dir.create(dirname(hex_shp), showWarnings = F)

  # setup hemispheres
  wrld <- dplyr::bind_rows(
    sf::st_sf(
      hemisphere = "west",
      geom = sf::st_as_sfc(
        sf::st_bbox(
          c(xmin = -180, xmax = 0, ymin = -86, ymax = 90),
          crs = sf::st_crs(4326)))),
    sf::st_sf(
      hemisphere = "east",
      geom = sf::st_as_sfc(
        sf::st_bbox(
          c(xmin = 0, xmax = 180, ymin = -86, ymax = 90),
          crs = sf::st_crs(4326))))) # mapview(wrld)

  # get hexagon ids for whole world (have to do by hemisphere)
  hexids <- c(
    h3::polyfill(wrld[1,], res = hex_res),
    h3::polyfill(wrld[2,], res = hex_res))

  # convert hexagon ids to spatial features
  hex_sf <- purrr::map_df(hexids, h3::h3_to_geo_boundary_sf) %>%
    dplyr::mutate(
      hexid = hexids) # mapview(hex_sf)

  # fix hexagons crossing dateline
  # hex_sf_0 <- hex_sf %>% select(-on_dtln)
  # hex_sf <- hex_sf_0
  hex_sf <- hex_sf %>%
    dplyr::mutate(
      on_dtln = purrr::map_lgl(geometry, function(g){
        max(diff(sf::st_coordinates(g)[,'X'])) > 300 } ))

  # hex_sf_1 <- hex_sf
  hex_sf <- rbind(
    hex_sf %>%
      filter(!on_dtln),
    # bind ok hex with those on dateline that we fix
    hex_sf %>%
      filter(on_dtln) %>%
      rowwise() %>%
      mutate(
        geometry = fix_dateline(geometry)))

  # hex_sf %>%
  #   # filter(!on_dtln) %>%
  #   mapview(zcol="hexid")

  # mapview(abnj) + mapview(hex_sf)
  # get intersection with Areas Beyond National Jurisdiction
  # x      <- st_intersects(hex_sf, abnj, sparse = F)[,1]
  # hex_sf <- hex_sf[x,]
  # mapview(abnj) + mapview(hex_sf)

  # add centroid lon, lat
  # hex_sf_2 <- hex_sf
  # hex_sf <- hex_sf_2
  hex_sf <- hex_sf %>%
    mutate(
      #geometry = st_cast(geometry, "MULTIPOLYGON"),
      # ctr = map(geometry, st_centroid),
      lon = map_dbl(geometry, function(g){
        st_centroid(g) %>% st_coordinates() %>%
          .[,'X'] }),
      lat = map_dbl(geometry, function(g){
        st_centroid(g) %>% st_coordinates() %>%
          .[,'Y'] }),
      area_km2 = map_dbl(geometry, st_area) %>%
        units::set_units(km^2) %>%
        units::drop_units())

  # mapview(hex_sf, zcol="area_km2")

  # mapview(abnj) + mapview(hex_sf)
  # clip hexagons to abnj
  # hex_sf_0 <- hex_sf
  # hex_sf <- hex_sf_0
  # hex_sf <- hex_sf %>%
  #   # st_wrap_dateline() %>%
  #   st_intersection(
  #     # st_wrap_dateline(
  #     abnj
  #     # )
  #   ) %>%
  #   filter(
  #     st_geometry_type(geometry) %in% c("POLYGON", "MULTIPOLYGON")) %>%
  #   mutate(
  #     geometry = st_cast(geometry, "MULTIPOLYGON")) %>%
  #   st_wrap_dateline()

  # st_geometry_type(hex_sf$geometry) %>% table()
  # mapview(abnj) + mapview(hex_sf)
  # leaflet(
  #  hex_sf,
  #  options = leafletOptions(worldCopyJump = T)) %>%
  #  addProviderTiles(providers$Esri.OceanBasemap) %>%
  #  addPolygons()

  # write out geojson and shapefile outputs
  # write_sf(hex_sf, hex_geo, delete_dsn=T)
  # write_sf(hex_sf, hex_shp, delete_dsn=T)
  # return(T)
  hex_sf
}
