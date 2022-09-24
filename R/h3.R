#' Make hexagon feature
#'
#' TODO: + sf feature or extent to minimize
#'
#' @param hex_res resolution of H3 hexagons; see [Table of Cell Areas for H3 Resolutions | H3](https://h3geo.org/docs/core-library/restable/)
#'
#' @return spatial feature `sf` object
#' @export
#' @import dplyr h3 purrr sf units glue
#'
#' @examples hexes <- make_hex_res(0)
make_hex_res <- function(hex_res = 2){
  # librarian::shelf(dplyr, h3, mapview, purrr, sf, units, glue)

  # paths
  # hex     <- glue("abnj_hex_res{hex_res}")
  # hex_geo <- glue(here("data/{hex}.geojson"))
  # hex_shp <- glue(here("data/{hex}_shp/{hex}.shp"))
  # dir.create(dirname(hex_shp), showWarnings = F)

  CRS <- sf::st_crs(4326)
  east <- sf::st_sf(
    geom = sf::st_as_sfc(
      sf::st_bbox(
        c(xmin = 0, xmax = 180, ymin = -90, ymax = 90),
        crs = CRS)))
  west <- sf::st_sf(
      geom = sf::st_as_sfc(
        sf::st_bbox(
          c(xmin = -180, xmax = 0, ymin = -90, ymax = 90),
          crs = CRS)))
  # mapview(world)

  hex_ids <- c(
    h3::polyfill(east, res=hex_res),
    h3::polyfill(west, res=hex_res)
  )

  # convert hexagon ids to spatial features
  # NOTE: DATELINEOFFSET is inv proportional to hex_res b/c we need to look
  #       further from the dateline as hex sizes get bigger.
  dl_offset <- 60  # 60 is enough for hex_res >= 1. res 0 is weird; don't use it.
  hex_sf <- purrr::map_df(hex_ids, h3::h3_to_geo_boundary_sf) %>%
    sf::st_wrap_dateline(c(
      "WRAPDATELINE=YES",
      glue::glue("DATELINEOFFSET={dl_offset}"))) %>%
    dplyr::mutate(
      hexid = hex_ids
    )

  # mapview(hex_sf)

  # # sanity check: see all hexagons have same area
  # hex_sf <- hex_sf %>%
  #   mutate(
  #     #geometry = st_cast(geometry, "MULTIPOLYGON"),
  #     # ctr = map(geometry, st_centroid),
  #     lon = map_dbl(geometry, function(g){
  #       st_centroid(g) %>% st_coordinates() %>%
  #         .[,'X'] }),
  #     lat = map_dbl(geometry, function(g){
  #       st_centroid(g) %>% st_coordinates() %>%
  #         .[,'Y'] }),
  #     area_km2 = map_dbl(geometry, st_area) %>%
  #       units::set_units(km^2) %>%
  #       units::drop_units())
  # mapview(hex_sf, zcol="area_km2")

  return(hex_sf)
}
