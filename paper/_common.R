# shared setup for the paper/ notebooks: load the package (dev checkout or
# installed), connect to the store named by OBIS_H3_DUCKDB, and set output dirs.
suppressMessages({
  library(DBI); library(duckdb); library(dplyr); library(ggplot2)
  if (file.exists("../DESCRIPTION") && requireNamespace("pkgload", quietly = TRUE))
    pkgload::load_all("..", quiet = TRUE) else library(obisindicators)
})

STORE <- Sys.getenv("OBIS_H3_DUCKDB", path.expand("~/_big/obis_h3_demo_gulf.duckdb"))
if (!file.exists(STORE))
  stop("no store at '", STORE, "' — set OBIS_H3_DUCKDB or run paper/build_demo_store.R")
con <- obis_store_connect(STORE)
knitr::knit_hooks$set(on_exit = function() DBI::dbDisconnect(con, shutdown = TRUE))

dir_fig <- "figures"; dir.create(dir_fig, showWarnings = FALSE)
store_label <- basename(STORE)
# map resolution: 3 for the global store (~12,000 km2 hexes), 4 for a regional demo
RES_MAP <- as.integer(Sys.getenv("PAPER_RES_MAP", if (grepl("demo", STORE)) 4L else 3L))
EOV_ORDER <- c("fish", "hardCorals", "mangroves", "marineMammals", "seabirds",
               "seagrasses", "seaTurtles")

# save a ggplot + its data side by side so figures are reproducible from csv
save_fig <- function(p, name, data = NULL, width = 9, height = 6, dpi = 200) {
  ggsave(file.path(dir_fig, paste0(name, ".png")), p, width = width, height = height, dpi = dpi)
  if (!is.null(data)) utils::write.csv(data, file.path(dir_fig, paste0(name, ".csv")), row.names = FALSE)
  invisible(p)
}
