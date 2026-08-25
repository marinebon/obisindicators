# shared helpers for the precomputed articles (vignettes/articles/*.Rmd.orig),
# which double as the manuscript's figure notebooks: label the store, pick map
# resolutions, and save each figure + the data behind it to paper/figures/.
# expects `con` (from obis_store_connect()) in the calling environment; source
# it with `source("../../paper/_common.R", local = TRUE)` from an article.

# this file lives in paper/, so figures go to paper/figures/ whatever the cwd
.frames <- Filter(function(f) !is.null(f$ofile), sys.frames())
dir_fig <- file.path(
  if (length(.frames)) dirname(normalizePath(.frames[[length(.frames)]]$ofile)) else "paper",
  "figures")
dir.create(dir_fig, showWarnings = FALSE, recursive = TRUE)

STORE       <- DBI::dbGetQuery(con, "PRAGMA database_list")$file[1]
store_label <- basename(STORE)
is_demo     <- grepl("demo", STORE)
store_note  <- if (is_demo)
  "a regional demo store (Gulf of Mexico + Caribbean, see `paper/build_demo_store.R`)" else
  "the global store"

# map resolution: 3 for the global store (~12,000 km2 hexes), 4 for a regional demo;
# period (decadal) resolution one step coarser so each cell-decade has enough records
RES_MAP  <- as.integer(Sys.getenv("PAPER_RES_MAP",  if (is_demo) 4L else 3L))
RES_TIME <- as.integer(Sys.getenv("PAPER_RES_TIME", if (is_demo) 3L else 2L))
EOV_ORDER <- c("fish", "hardCorals", "mangroves", "marineMammals", "seabirds",
               "seagrasses", "seaTurtles")

# save a ggplot + its data side by side, so every manuscript figure is
# reproducible from its csv
save_fig <- function(p, name, data = NULL, width = 9, height = 6, dpi = 200) {
  ggplot2::ggsave(file.path(dir_fig, paste0(name, ".png")), p,
                  width = width, height = height, dpi = dpi)
  if (!is.null(data)) save_tab(data, name)
  invisible(p)
}
save_tab <- function(data, name)
  utils::write.csv(data, file.path(dir_fig, paste0(name, ".csv")), row.names = FALSE)
