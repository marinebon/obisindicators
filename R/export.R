# export an obis_h3 DuckDB store to hive-partitioned Parquet for a serverless
# web app (static hosting + DuckDB-WASM + deck.gl H3HexagonLayer). the
# precomputed layers are copied as-is; the per-decade layers are computed here
# with the same SQL (.h3t_indicators_sql()) that builds idx_h3 / idx_h3_eov.

# columns of every indicator parquet file, documented in release.json ----
EXPORT_COLUMNS <- list(
  h3      = "H3 cell index as a lowercase hex string (deck.gl H3HexagonLayer getHexagon)",
  cell_id = "H3 cell index as BIGINT (same cell as h3)",
  n       = "number of occurrence records",
  sp      = "species richness (distinct species names)",
  shannon = "Shannon diversity H' = -sum(p_i ln p_i) over species",
  simpson = "Simpson index sum(p_i^2) over species",
  es      = "Hurlbert expected number of species in a random draw of 50 records, ES(50); NULL where n < 50")

EXPORT_VARS <- c("n", "sp", "shannon", "simpson", "es")

# max partitions written by one COPY (open files; DuckDB's own default cap)
EXPORT_MAX_OPEN <- 100L

#' Export an obis_h3 store to hive-partitioned Parquet
#'
#' Writes the indicator layers of a store built by [build_obis_h3_duckdb()] to
#' a directory of hive-partitioned Parquet files that a static web app can read
#' directly with DuckDB-WASM (one small file per map layer and H3 resolution):
#'
#' ```
#' <dir_out>/<release>/
#'   release.json                              build metadata, row counts, layout, columns, file manifest
#'   all/res=<1..5>/data_0.parquet             idx_h3 (all taxa, all years)
#'   all/res=<6,7>/p=<parent>/data_0.parquet   the fine res, one file per parent cell
#'   eov/eov=<eov>/res=<r>/data_0.parquet      idx_h3_eov
#'   taxon/rank=<rank>/taxon=<taxon>/res=<r>/  idx_h3_taxon (phylum / class / order / family),
#'                                             plus the heads (kingdom, subphylum, superclass ...)
#'   decade/all/decade=<yyy0>/res=<r>/         per decade, all taxa  (res in res_decade)
#'   decade/eov/eov=<eov>/decade=<yyy0>/res=<r>/  per decade and EOV (res in res_decade)
#'   year/all/year=<yyyy>/res=<r>/             per year, all taxa    (res in res_year)
#'   year/eov/eov=<eov>/year=<yyyy>/res=<r>/   per year and EOV      (res in res_year)
#'   species/res=<r>/class=<class>/data_0.parquet  species x hex x count (res in res_species)
#'   species/species.parquet                   the species lookup: names, name_key, lineage
#'   species/heads.json                        the pre-aggregated heads and the layer serving each
#'   species_decade/res=<r>/decade=<d>/class=<class>/  per decade (res in res_species_decade)
#'   species_flat/res=<r>.parquet              one cell-sorted file, every class (res_species_flat)
#'   place/coll=<slug>/data_0.parquet          per-place pooled indicators (only with place_collections)
#'   place_exact/coll=<slug>/indicators.parquet, years.parquet, meta.json
#'                                             exact point-in-polygon indicators (only with place_exact)
#'   collection.json                           STAC Collection (h3 profile), obis_h3_stac_collection()
#'   stats.parquet                             value ranges per layer x key x period x res x variable
#'   taxon_groups.parquet                      the taxa and EOVs available, with totals and paths
#'   files.parquet                             manifest: layer, path, url_path, rows, bytes per file
#' ```
#'
#' Every indicator file has the columns `h3` (lowercase hex string), `cell_id`,
#' `n`, `sp`, `shannon`, `simpson`, `es`; the partition keys live in the path
#' (read with `hive_partitioning = true`). Its rows are sorted by `cell_id` in
#' row groups of `row_group_rows` (about 10k), so a reader that knows the cells
#' under a tile reads only the row groups whose `cell_id` statistics overlap
#' them (a range read) instead of the whole file. Each file is written by its
#' own `COPY` ([obis_h3_write_partitions()]), since DuckDB's `PARTITION_BY`
#' does not keep the order. The decade layers are computed from
#' `occ_h3` with the same SQL builder as `idx_h3` / `idx_h3_eov` (so the math is
#' identical to the store): `n` = records, `sp` = distinct species, Shannon,
#' Simpson and ES(`esn`), grouped by cell and `decade = floor(date_year / 10) *
#' 10`; records without a year are left out of the decade layers. EOV membership
#' is the store's `eov` table (`occ_h3.aphiaid = eov.taxonID`), as in
#' [obis_eov_bake()]. Layers whose source tables are missing (e.g. no
#' `idx_h3_eov` in a store without taxonomy) are skipped with a message.
#'
#' Partition values are percent-encoded by DuckDB (a space becomes `%20`), and
#' DuckDB decodes them on read. A static web server decodes the URL once, so a
#' browser must request the on-disk name with `%` itself encoded (`%2520`);
#' `taxon_groups.parquet` carries both `path` (on disk) and `url_path` (to
#' fetch), and `files.parquet` lists every file with both forms. Each partition
#' is exactly one `data_0.parquet`.
#'
#' **Parent partitions for the fine resolutions.** A whole res-7 layer is tens
#' of MB, too much for a browser to load at once, so the resolutions named in
#' `parent_res` are split by parent cell: every row of `all/res=7/` goes to
#' `all/res=7/p=<h3 of its res-3 parent>/data_0.parquet` (default res 6 by its
#' res-2 parent, res 7 by its res-3 parent), and a viewer loads only the parent
#' cells that cover its viewport. The taxon layer uses `parent_res_taxon`
#' (default the res-0 base cell: res-3 parents would make over a million
#' files across ~5k taxa). A (layer key, res) with at most `parent_min_rows`
#' rows stays one whole file, since splitting it would only add requests. The
#' decade layers are never split (their default resolutions are 1-5).
#' `files.parquet` has a `parent` column (the partition's parent cell, NULL for
#' a whole file; its resolution is the parent resolution), and each layer in
#' `release.json` lists the `parent_res` actually used.
#'
#' **Place layer (optional).** With `place_collections`, each gazetteer
#' collection gets one file, `place/coll=<slug>/data_0.parquet`, with the
#' indicators of every place pooled from its res-7 member cells, records
#' weighted by each cell's share of area inside the place
#' ([obis_place_indicators()]): columns `place_id`, `layer` (`all` | `eov`),
#' `key` ('' or the EOV), `decade` (NULL = all years, else the decades above),
#' `n` (fractional), `sp`, `shannon`, `simpson`, `es`, `cells`, `area`. These
#' are true per-place indices of the pooled, area-weighted counts, not means of
#' hexagon values. The files are listed in `files.parquet` (layer `place`) and
#' `release.json` (`layers$place`, with each collection's membership version);
#' `stats.parquet` does not cover them.
#'
#' **Exact place layer (optional).** With `place_exact`, each polygon collection gets
#' `place_exact/coll=<slug>/indicators.parquet` and `years.parquet`
#' ([obis_place_indicators_exact()], written by [obis_place_exact_write()]):
#' the indicators of every place computed from the OBIS occurrences inside the true
#' polygon, with no H3 approximation, per EOV (`all` and the store's `eov` table), per
#' decade and per year, with Berger-Parker and density. They are values only (no
#' geometry), computed from the occurrence parquet files `place_exact_occ` (the local
#' snapshot the store was built from), which takes far longer than the layers above.
#' The files are listed in `files.parquet` (layer `place_exact`) and `release.json`
#' (`layers$place_exact`, with each collection's places and record totals);
#' `stats.parquet` does not cover them.
#'
#' **Year layers.** `year/all` and `year/eov` are the decade layers per year:
#' the same SQL ([obis_h3_year_sql()]) grouped by `year = date_year`, one
#' partition per year present from `min(date_year)` to `max(date_year)` (or
#' the `years` asked for), at the resolutions `res_year` (default 1-5, never
#' split by parent). `release.json` lists the years written (`years`).
#'
#' **The species table** (`species/`, spike 2 of the Ocean Metrics
#' restructure): one row per (cell, aphiaid) with `n` = records, at the
#' resolutions `res_species` (default 3, 4, 5; res 4 rolled up from the res-5
#' tier), so a browser answers a WoRMS subtree or "which species are in this
#' cell" from static files. Columns `h3, cell_id, name_key, aphiaid, n`
#' ([obis_h3_species_sql()]); one `data_0.parquet` per (res, class) written by
#' [obis_h3_write_partitions()], sorted by `cell_id, aphiaid` in row groups of
#' 100k; a NULL class is `class=_none`. `species/species.parquet`
#' ([obis_h3_species_lookup_sql()]) has one row per aphiaid with its names, a
#' `name_key` per distinct name (richness counts names) and its `lineage`
#' (self, then ancestors up the store's `taxon` table); a subtree is
#' `list_contains(lineage, <aphiaid>)` ([obis_h3_species_subtree_sql()]).
#' `species/heads.json` lists the taxa that need a pre-aggregated head
#' ([obis_h3_species_heads()]: Animalia and every taxon spanning two or more
#' named classes) and the layer that serves each. Each species row also
#' carries `year_min` and `year_max`, the first and last year the aphiaid was
#' recorded in the cell (within the decade in `species_decade/`), for the Cell
#' pane. `species_flat/res=<r>.parquet` (default res 3) is the same table in one
#' file for every class, sorted by `cell_id, aphiaid` in row groups of
#' `row_group_rows`, so the species of one cell are a range read of one file
#' (spike 2: 0.53 MB for a res-1 cell) instead of one row group per class file.
#'
#' **The heads** (`heads = TRUE`) are written as ordinary taxon layers,
#' `taxon/rank=<rank>/taxon=<name>/res=<r>/` at `res_heads`
#' ([obis_h3_heads_sql()]: the WoRMS subtree from the lineage, species counted by
#' `name_key`, so a head equals [obis_h3_species_subtree_sql()] cell for cell),
#' where `rank` is the WoRMS rank lowercased without a botanical alias
#' ("Phylum (Division)" is `phylum`). They then appear in `stats.parquet`,
#' `taxon_groups.parquet` and `files.parquet` as any taxon. A head is not
#' written when a layer already serves it: one whose subtree holds every
#' aphiaid (and the store has no record without one) is the `all` layer; one
#' whose rank and name are a rank layer of `idx_h3_taxon` keeps that layer
#' (built from the OBIS rank column, not the WoRMS subtree, so it may differ in
#' a few cells). `heads.json` gives each head's `served_by` (`head`, `all`,
#' `rank_layer`, or `homonym` for a second taxon with the same rank and name)
#' and its `layer`. The per-decade variant
#' `species_decade/` is written only with `species_decades = TRUE`. Rows with
#' no aphiaid are left out; a store without one (e.g. the demo store built from
#' `occ_SAtlantic`) gets no species layer.
#'
#' `collection.json` is a STAC Collection of the release for the Ocean Metrics
#' `h3` profile ([obis_h3_stac_collection()]).
#'
#' `stats.parquet` has one row per indicator layer and (`key`, `decade`,
#' `year`, `res`, `variable`) with `min`, `p02`, `p50`, `p98`, `max` and
#' `n_cells` (cells with a non-NULL value; a variable NULL everywhere in a
#' partition gets a row with NULL ranges and `n_cells` 0), for colour ramps.
#' `key` is the EOV or taxon name ('' for the all-taxa layers), `rank` the
#' taxon rank ('' otherwise), `decade` NA outside the decade layers, `year` NA
#' outside the year layers.
#'
#' @param con connection from [obis_store_connect()] (read-only is fine).
#' @param dir_out output directory; files go under `dir_out/release/`.
#' @param release release tag, e.g. `"v20260728"` (the date of the OBIS sync
#'   the store was built from); recorded in `release.json`. Its
#'   `obis_snapshot` is the environment variable `OBIS_DATA_DATE` (the newest
#'   OBIS object's date, which `refresh_obis_h3.sh` passes) when that is a
#'   `YYYY-MM-DD` date, else the date in the tag.
#' @param res_decade H3 resolutions for the decade layers (default 1-5).
#' @param res_year H3 resolutions for the year layers (default 1-5);
#'   `integer(0)` skips them.
#' @param years years to export in the year layers; default NULL, every year
#'   present.
#' @param res_species H3 resolutions of the species table (default 3, 4, 5);
#'   `integer(0)` skips it.
#' @param species_decades also write the per-decade species table
#'   `species_decade/` (default TRUE, 0.11.0), at `res_species_decade`.
#' @param res_species_decade the resolutions of the per-decade species table
#'   (default 3 and 4: the decade filter on a WoRMS subtree).
#' @param res_species_flat the resolutions of the unpartitioned species table
#'   `species_flat/res=<r>.parquet` (default 3: the cell query); `integer(0)`
#'   skips it.
#' @param heads write the pre-aggregated heads as taxon layers (default TRUE;
#'   needs the species table and the store's `taxon` table).
#' @param res_heads the resolutions of the heads (default 1-7; res 6 and 7 are
#'   split by `parent_res_taxon` like the rank layers).
#' @param parent_res named integer vector, fine resolution -> parent
#'   resolution, for the `all` and `eov` layers: those resolutions are written
#'   one file per parent cell (`res=<r>/p=<parent>/`). Default
#'   `c("6" = 2L, "7" = 3L)`; `NULL` writes every resolution whole.
#' @param parent_res_taxon the same for the taxon layer (default
#'   `c("6" = 0L, "7" = 0L)`, the base cell).
#' @param parent_min_rows a (layer key, res) with at most this many rows is
#'   written whole even when its res is in `parent_res` (default 50000).
#' @param max_open no longer used (0.11.0): every file is written by its own
#'   `COPY`, so no more than one is open at a time. Kept so old calls still run.
#' @param compression Parquet compression codec (default `"zstd"`).
#' @param row_group_rows rows per Parquet row group of the indicator layer
#'   files (default 10000; DuckDB rounds up to a multiple of 2048, so a group
#'   holds at most 10,240). Recorded in `release.json` (`row_group_rows`, and
#'   the largest group written as `row_group_rows_max`).
#' @param overwrite replace an existing `dir_out/release/` (default FALSE: stop).
#' @param decades decades (first year) to export in the decade layers; default
#'   1960-2020. NULL exports every decade present.
#' @param esn expected sample size for ES(n) in the decade layers; default 50
#'   (as in the store).
#' @param place_collections optional named list (or character vector), slug =
#'   the gazetteer collection's membership (a directory or URL, its
#'   `membership.json`, or anything [obis_place_indicators()] takes as
#'   `membership`), e.g. `list(eez = "<gazetteer base>/eez")`. Default `NULL`:
#'   no place layer.
#' @param place_exact optional named list (or character vector), slug = the path
#'   of the collection's GeoParquet of polygons (`place_id`, WKB `geometry`, an
#'   optional `area_km2`), e.g. `list(mr_eez = "<places-internal>/mr_eez/places.parquet")`.
#'   Default `NULL`: no exact place layer. Needs `place_exact_occ`.
#' @param place_exact_occ the occurrence parquet path(s)/glob(s) the exact place
#'   indicators are computed from (OBIS open data, nested or flat; see
#'   [obis_place_indicators_exact()]).
#' @param temp_dir,max_temp_dir_size DuckDB spill directory and cap for the exact
#'   place computation (it runs in its own DuckDB instance with this
#'   `memory_limit` and `threads`).
#' @param memory_limit optional DuckDB `memory_limit` (e.g. `"24GB"`).
#' @param threads optional DuckDB thread count (e.g. `8`).
#' @param verbose print progress and the summary (default TRUE).
#'
#' @return invisibly, a character vector of the files written (absolute paths).
#' @concept store
#' @export
#' @examples
#' \dontrun{
#' con <- obis_store_connect("~/data/obis/obis_h3.duckdb")
#' obis_h3_export_parquet(con, "~/data/obis-h3", "v20260728")
#' }
obis_h3_export_parquet <- function(
  con,
  dir_out,
  release,
  res_decade       = 1:5,
  res_year         = 1:5,
  years            = NULL,
  res_species      = c(3L, 4L, 5L),
  species_decades  = TRUE,
  res_species_decade = c(3L, 4L),
  res_species_flat = 3L,
  heads            = TRUE,
  res_heads        = 1:7,
  parent_res       = c("6" = 2L, "7" = 3L),
  parent_res_taxon = c("6" = 0L, "7" = 0L),
  parent_min_rows  = 50000,
  max_open         = EXPORT_MAX_OPEN,
  compression  = "zstd",
  row_group_rows = 10000L,
  overwrite    = FALSE,
  decades      = seq(1960L, 2020L, by = 10L),
  esn          = 50L,
  place_collections = NULL,
  place_exact       = NULL,
  place_exact_occ   = NULL,
  temp_dir          = NULL,
  max_temp_dir_size = NULL,
  memory_limit = NULL,
  threads      = NULL,
  verbose      = TRUE) {

  stopifnot(
    requireNamespace("DBI", quietly = TRUE),
    requireNamespace("jsonlite", quietly = TRUE),
    is.character(release), length(release) == 1L,
    grepl("^[A-Za-z0-9._-]+$", release),
    is.character(compression), length(compression) == 1L,
    grepl("^[A-Za-z0-9]+$", compression),
    all(as.integer(res_decade) %in% H3T_RES_IDX),
    all(as.integer(res_year) %in% H3T_RES_IDX),
    all(as.integer(res_species) %in% H3T_RES_IDX),
    all(as.integer(res_heads) %in% H3T_RES_IDX),
    all(as.integer(res_species_decade) %in% H3T_RES_IDX),
    all(as.integer(res_species_flat) %in% H3T_RES_IDX),
    is.logical(heads), length(heads) == 1L,
    is.null(years) || is.numeric(years),
    is.logical(species_decades), length(species_decades) == 1L,
    is.numeric(parent_min_rows), length(parent_min_rows) == 1L,
    is.numeric(max_open), length(max_open) == 1L, max_open >= 1,
    is.numeric(row_group_rows), length(row_group_rows) == 1L, row_group_rows >= 1)
  check_pr <- function(pr) {
    if (is.null(pr) || !length(pr)) return(integer(0))
    stopifnot(!is.null(names(pr)), !anyNA(suppressWarnings(as.integer(names(pr)))),
              all(as.integer(pr) >= 0L), all(as.integer(pr) < as.integer(names(pr))))
    stats::setNames(as.integer(pr), as.integer(names(pr)))
  }
  parent_res       <- check_pr(parent_res)
  parent_res_taxon <- check_pr(parent_res_taxon)
  max_open         <- as.integer(max_open)
  row_group_rows   <- as.integer(row_group_rows)
  t0  <- Sys.time()
  say <- function(...) if (verbose) message(...)
  res_decade  <- sort(unique(as.integer(res_decade)))
  res_year    <- sort(unique(as.integer(res_year)))
  res_species <- sort(unique(as.integer(res_species)))
  res_heads   <- sort(unique(as.integer(res_heads)))
  res_species_decade <- sort(unique(as.integer(res_species_decade)))
  res_species_flat   <- sort(unique(as.integer(res_species_flat)))
  esn        <- as.integer(esn)

  out <- normalizePath(file.path(path.expand(dir_out), release), mustWork = FALSE)
  if (dir.exists(out)) {
    if (!overwrite)
      stop("output exists and overwrite = FALSE: ", out)
    unlink(out, recursive = TRUE)
  }
  dir.create(out, recursive = TRUE, showWarnings = FALSE)
  out <- normalizePath(out)  # resolve symlinks (e.g. /tmp) to match DuckDB paths

  # resource guards ----
  # one file per partition: DuckDB otherwise closes a partition's file once more
  # than partitioned_write_max_open_files (default 100) are open and starts a
  # data_1.parquet for it (the global taxon layer has ~11k partitions)
  DBI::dbExecute(con, "SET preserve_insertion_order = false;")
  DBI::dbExecute(con, "SET partitioned_write_max_open_files = 1000000;")
  on.exit({
    DBI::dbExecute(con, "RESET preserve_insertion_order;")
    DBI::dbExecute(con, "RESET partitioned_write_max_open_files;")
  }, add = TRUE)
  if (!is.null(memory_limit))
    DBI::dbExecute(con, glue::glue("SET memory_limit = '{memory_limit}';"))
  if (!is.null(threads))
    DBI::dbExecute(con, glue::glue("SET threads = {as.integer(threads)};"))

  has  <- function(t) .obis_has_table(con, t)
  if (!has("idx_h3")) stop("store has no idx_h3 table")
  q    <- function(x) gsub("'", "''", x)  # escape a path for a SQL literal
  cols <- "lower(printf('%x', cell_id)) AS h3, cell_id, n, sp, shannon, simpson, es"

  # one data_0.parquet per partition, its rows in cell_id order in row groups of
  # row_group_rows, so a reader range-reads only the groups under its parent cells:
  # one COPY per partition (obis_h3_write_partitions(); PARTITION_BY loses the order) ----
  write_sorted <- function(sql, sub, parts) {
    w <- obis_h3_write_partitions(con, sql, file.path(out, sub), partition_by = parts,
                                  order_by = "cell_id", compression = compression,
                                  row_group_size = row_group_rows)
    sum(w$rows)
  }
  lit <- function(v) if (is.character(v)) .h3t_sql_quote(v) else as.character(as.integer(v))
  # a VALUES list of partition tuples (one column per entry of `parts`), for a SEMI or ANTI JOIN
  tuples <- function(g, parts) paste0(
    "(", do.call(paste, c(lapply(parts, function(p) lit(g[[p]])), sep = ", ")), ")",
    collapse = ", ")
  layers <- list()
  add_layer <- function(name, sub, parts, rows, pr_used = integer(0)) {
    l <- list(
      path       = sub,
      partitions = I(parts),
      template   = paste0(sub, "/", paste0(parts, "=<", parts, ">", collapse = "/"),
                          "/data_0.parquet"),
      rows       = rows)
    if (length(pr_used)) {
      l$parent_res      <- as.list(pr_used)
      l$template_parent <- sub("/data_0.parquet$", "/p=<parent>/data_0.parquet",
                               l$template)
    }
    layers[[name]] <<- l
  }

  # a precomputed layer (idx_h3, idx_h3_eov, idx_h3_taxon): whole files per
  # (keys, res), except the res in `pr` with more than parent_min_rows rows,
  # which go one file per parent cell (res=<r>/p=<parent>/); written in slices of
  # its first key (each EOV, each taxon rank), so each sorted temp table stays small ----
  write_layer <- function(name, sub, from, keys, pr, register = TRUE) {
    parts <- c(keys, "res")
    kc    <- paste0(keys, ", ", collapse = "")
    if (!length(keys)) kc <- ""
    grp <- DBI::dbGetQuery(con, glue::glue(
      "SELECT {kc}res::INTEGER AS res, COUNT(*)::DOUBLE AS n
       FROM {from} GROUP BY ALL ORDER BY ALL"))
    fine    <- grp$res %in% as.integer(names(pr)) & grp$n > parent_min_rows
    pr_used <- pr[as.character(sort(unique(grp$res[fine])))]
    p_expr  <- if (any(fine)) paste0("CASE res ", paste(sprintf(
      "WHEN %d THEN lower(printf('%%x', h3_cell_to_parent(cell_id, %d)))",
      as.integer(names(pr_used)), pr_used), collapse = " "), " END")
    pj      <- paste(parts, collapse = ", ")
    slices  <- if (length(keys)) unique(grp[[keys[1]]]) else NA
    rows    <- 0
    n_par   <- 0
    for (s in slices) {
      in_s  <- if (length(keys)) grp[[keys[1]]] == s else rep(TRUE, nrow(grp))
      where <- if (length(keys)) glue::glue("{keys[1]} = {lit(s)}") else "TRUE"
      whole <- glue::glue("SELECT {kc}res, {cols} FROM {from} WHERE {where}")
      if (any(fine & in_s))
        whole <- glue::glue(
          "SELECT * FROM ({whole}) _s ANTI JOIN (VALUES {tuples(grp[fine & in_s, ], parts)}) _v({pj}) USING ({pj})")
      if (any(!fine & in_s)) rows <- rows + write_sorted(whole, sub, parts)
      if (any(fine & in_s)) {
        src <- glue::glue(
          "SELECT {kc}res, {p_expr} AS p, {cols} FROM {from}
           WHERE {where} AND res IN ({paste(names(pr_used), collapse = ', ')})")
        src <- glue::glue(
          "SELECT * FROM ({src}) _s SEMI JOIN (VALUES {tuples(grp[fine & in_s, ], parts)}) _v({pj}) USING ({pj})")
        w <- obis_h3_write_partitions(con, src, file.path(out, sub), partition_by = c(parts, "p"),
                                      order_by = "cell_id", compression = compression,
                                      row_group_size = row_group_rows)
        rows  <- rows + sum(w$rows)
        n_par <- n_par + nrow(w)
      }
    }
    if (n_par) say("  ", n_par, " parent partitions for res ", paste(names(pr_used), collapse = ", "))
    if (register) add_layer(name, sub, parts, rows, pr_used)
    invisible(list(rows = rows, pr_used = pr_used))
  }

  say("all: idx_h3 ...")
  write_layer("all", "all", "idx_h3", character(0), parent_res)

  if (has("idx_h3_eov")) {
    say("eov: idx_h3_eov ...")
    write_layer("eov", "eov", "idx_h3_eov", "eov", parent_res)
  } else say("skipping eov: no idx_h3_eov table")

  if (has("idx_h3_taxon")) {
    say("taxon: idx_h3_taxon ...")
    write_layer("taxon", "taxon", "idx_h3_taxon", c("rank", "taxon"), parent_res_taxon)
  } else say("skipping taxon: no idx_h3_taxon table")

  # decade layers: computed from occ_h3 with the store's indicator SQL ----
  has_eov  <- has("eov")
  rows_all <- 0
  rows_eov <- 0
  for (r in res_decade) {
    say("decade res ", r, " (occ_h3 tier ", .obis_tier(r), ") ...")
    rows_all <- rows_all + write_sorted(
      .obis_h3_period_sql(r, "decade", periods = decades, esn = esn),
      "decade/all", c("decade", "res"))
    if (has_eov)
      rows_eov <- rows_eov + write_sorted(
        .obis_h3_period_sql(r, "decade", eov = TRUE, periods = decades, esn = esn),
        "decade/eov", c("eov", "decade", "res"))
  }
  add_layer("decade_all", "decade/all", c("decade", "res"), rows_all)
  if (has_eov)
    add_layer("decade_eov", "decade/eov", c("eov", "decade", "res"), rows_eov)
  else say("skipping decade_eov: no eov table")

  # place layer: per-place pooled, area-weighted indicators, one file per collection ----
  if (length(place_collections)) {
    slugs <- names(place_collections)
    stopifnot(
      "place_collections must be named by collection slug" =
        !is.null(slugs) && all(grepl("^[A-Za-z0-9._-]+$", slugs)) && !anyDuplicated(slugs))
    dec_place <- decades
    if (is.null(dec_place))
      dec_place <- DBI::dbGetQuery(con, glue::glue(
        "SELECT DISTINCT CAST(floor(date_year / 10) * 10 AS INTEGER) AS d
         FROM occ_h3 WHERE date_year IS NOT NULL ORDER BY 1"))$d
    rows_place <- 0
    colls      <- list()
    for (slug in slugs) {
      say("place: ", slug, " ...")
      mem <- place_collections[[slug]]
      if (is.character(mem) && length(mem) == 1L && !grepl("\\.parquet$", mem) &&
          !mem %in% DBI::dbListTables(con))
        mem <- obis_place_membership(mem, res = 7L)
      pl <- obis_place_indicators(con, mem, esn = esn, res = 7L,
                                  decades = if (length(dec_place)) dec_place else FALSE,
                                  eov = has_eov)
      d  <- file.path(out, "place", paste0("coll=", slug))
      dir.create(d, recursive = TRUE, showWarnings = FALSE)
      vw <- "export_place"
      duckdb::duckdb_register(con, vw, pl)
      DBI::dbExecute(con, glue::glue("
        COPY (
          SELECT place_id::VARCHAR AS place_id, layer::VARCHAR AS layer, key::VARCHAR AS key,
                 decade::INTEGER AS decade, n::DOUBLE AS n, sp::INTEGER AS sp,
                 shannon::DOUBLE AS shannon, simpson::DOUBLE AS simpson, es::DOUBLE AS es,
                 cells::INTEGER AS cells, area::DOUBLE AS area
          FROM {vw} ORDER BY place_id, layer, key, decade NULLS FIRST
        ) TO '{q(file.path(d, 'data_0.parquet'))}' (FORMAT PARQUET, COMPRESSION {compression});"))
      duckdb::duckdb_unregister(con, vw)
      rows_place <- rows_place + nrow(pl)
      info <- if (is.list(mem) && !is.data.frame(mem)) mem$info else NULL
      colls[[slug]] <- list(
        source             = if (is.character(place_collections[[slug]]))
                               place_collections[[slug]][1] else NULL,
        res                = 7L,
        places             = length(unique(pl$place_id)),
        collection_version = info$collection_version,
        places_sha256      = info$places_sha256,
        membership_version = info$version)
    }
    add_layer("place", "place", "coll", rows_place)
    layers$place$collections <- colls
    layers$place$columns <- I(c("place_id", "layer", "key", "decade", "n", "sp", "shannon",
                                "simpson", "es", "cells", "area"))
    layers$place$note <- paste(
      "one row per place x layer (all | eov) x key ('' | EOV) x decade (NULL = all years):",
      "indicators of the place's species counts pooled over its res-7 member cells, each",
      "cell's records weighted by its share of area inside the place (gazetteer",
      "membership, shares >= 0.01), so n is fractional; true per-place indices, not means",
      "of hexagon values. sp counts every species with a weighted record; es is NULL",
      "where n < esn; cells = member cells with records, area = their summed share.")
  }

  # exact place layer: point-in-polygon indicators from the occurrence files, values only ----
  if (length(place_exact)) {
    slugs_x <- names(place_exact)
    stopifnot(
      "place_exact must be named by collection slug" =
        !is.null(slugs_x) && all(grepl("^[A-Za-z0-9._-]+$", slugs_x)) && !anyDuplicated(slugs_x),
      "place_exact needs place_exact_occ (the occurrence parquet files)" =
        is.character(place_exact_occ) && length(place_exact_occ) >= 1L)
    rows_x <- 0
    colls_x <- list()
    for (slug in slugs_x) {
      say("place_exact: ", slug, " ...")
      px  <- obis_place_indicators_exact(
        place_exact_occ, as.character(place_exact[[slug]]),
        eov = if (has_eov) con else NULL,
        decades = if (is.null(decades)) TRUE else decades, years = TRUE, esn = esn,
        memory_limit = memory_limit, threads = threads, temp_dir = temp_dir,
        max_temp_dir_size = max_temp_dir_size, verbose = verbose)
      obis_place_exact_write(px, out, slug)
      rows_x <- rows_x + nrow(px$indicators) + nrow(px$years)
      dg <- px$diagnostics
      colls_x[[slug]] <- list(
        source        = as.character(place_exact[[slug]])[1],
        places        = length(unique(px$indicators$place_id)),
        records_in    = dg$records_in,
        records_out   = dg$records_out,
        records_total = dg$records_total,
        overlaps      = dg$overlaps$n)
    }
    add_layer("place_exact", "place_exact", "coll", rows_x)
    pxl <- .pe_layer_meta()
    layers$place_exact$template <- pxl$template
    layers$place_exact$collections <- colls_x
    layers$place_exact$columns <- pxl$columns
    layers$place_exact$note <- pxl$note
  }

  # year layers: the same per year, from min(date_year) to max(date_year) ----
  # (each res is computed once into a temp table, then written one sorted file per partition)
  occ_cols  <- names(DBI::dbGetQuery(con, "SELECT * FROM occ_h3 LIMIT 0"))
  yr_rng    <- data.frame(lo = NA_integer_, hi = NA_integer_)
  if (length(res_year) && "date_year" %in% occ_cols)
    yr_rng <- DBI::dbGetQuery(con, "
      SELECT MIN(date_year)::INTEGER AS lo, MAX(date_year)::INTEGER AS hi FROM occ_h3")
  yrs_out   <- integer(0)
  if (length(res_year) && !is.na(yr_rng$lo)) {
    rows_yall <- 0
    rows_yeov <- 0
    on.exit(DBI::dbExecute(con, "DROP TABLE IF EXISTS _export_year;"), add = TRUE)
    for (r in res_year) for (e in c(FALSE, if (has_eov) TRUE)) {
      say("year res ", r, if (e) " x eov" else "", " (occ_h3 tier ", .obis_tier(r), ") ...")
      DBI::dbExecute(con, glue::glue(
        "CREATE OR REPLACE TEMP TABLE _export_year AS
         {obis_h3_year_sql(r, eov = e, years = years, esn = esn)}"))
      parts <- c(if (e) "eov", "year", "res")
      grp   <- DBI::dbGetQuery(con, glue::glue(
        "SELECT DISTINCT {paste(parts, collapse = ', ')} FROM _export_year ORDER BY ALL"))
      n <- write_sorted("SELECT * FROM _export_year", if (e) "year/eov" else "year/all", parts)
      if (e) rows_yeov <- rows_yeov + n else {
        rows_yall <- rows_yall + n
        yrs_out   <- sort(unique(c(yrs_out, as.integer(grp$year))))
      }
    }
    DBI::dbExecute(con, "DROP TABLE IF EXISTS _export_year;")
    add_layer("year_all", "year/all", c("year", "res"), rows_yall)
    if (has_eov)
      add_layer("year_eov", "year/eov", c("eov", "year", "res"), rows_yeov)
  } else if (length(res_year)) say("skipping year layers: no date_year in occ_h3")

  # species x hex x count table: species/res=<r>/class=<class>/data_0.parquet ----
  # plus the lookup (species/species.parquet) and the heads still to build
  # (species/heads.json); one explicit COPY per partition, sorted by cell
  sp_need <- c("res", "cell_id", "aphiaid", "species", "genus", "family", "order",
               "class", "phylum", "records")
  n_heads <- NA_integer_
  if (length(res_species) && all(sp_need %in% occ_cols)) {
    taxon_tbl <- if (has("taxon")) "taxon" else NULL
    if (is.null(taxon_tbl)) say("species: no taxon table, so each lineage is the aphiaid alone")
    lk <- "_export_species_lookup"
    on.exit(DBI::dbExecute(con, glue::glue("DROP TABLE IF EXISTS {lk};")), add = TRUE)
    say("species lookup ...")
    DBI::dbExecute(con, glue::glue(
      "CREATE OR REPLACE TEMP TABLE {lk} AS {obis_h3_species_lookup_sql(taxon = taxon_tbl)}"))
    n_lookup <- DBI::dbGetQuery(con, glue::glue("SELECT COUNT(*)::DOUBLE AS n FROM {lk}"))$n
    if (n_lookup > 0) {
      dir.create(file.path(out, "species"), showWarnings = FALSE)
      DBI::dbExecute(con, glue::glue(
        "COPY (SELECT * FROM {lk} ORDER BY aphiaid) TO '{q(file.path(out, 'species', 'species.parquet'))}'
         (FORMAT PARQUET, COMPRESSION {compression}, ROW_GROUP_SIZE 100000);"))
      rows_sp <- 0
      for (r in res_species) {
        say("species res ", r, " (occ_h3 tier ", .obis_tier(r), ") ...")
        w <- obis_h3_write_partitions(
          con, obis_h3_species_sql(r, lookup = lk),
          file.path(out, "species", paste0("res=", r)),
          partition_by = "class", order_by = c("cell_id", "aphiaid"),
          compression = compression)
        rows_sp <- rows_sp + sum(w$rows)
      }
      add_layer("species", "species", c("res", "class"), rows_sp)

      if (species_decades && length(res_species_decade)) {
        rows_sd <- 0
        for (r in res_species_decade) {
          say("species x decade res ", r, " ...")
          w <- obis_h3_write_partitions(
            con, obis_h3_species_sql(r, lookup = lk, decade = TRUE, decades = decades),
            file.path(out, "species_decade", paste0("res=", r)),
            partition_by = c("decade", "class"), order_by = c("cell_id", "aphiaid"),
            compression = compression)
          rows_sd <- rows_sd + sum(w$rows)
        }
        add_layer("species_decade", "species_decade", c("res", "decade", "class"), rows_sd)
        layers$species_decade$kind          <- "species"
        layers$species_decade$href_template <-
          "species_decade/res={res}/decade={decade}/class={class}/data_0.parquet"
        layers$species_decade$resolutions   <- I(res_species_decade)
        layers$species_decade$decades       <- if (is.null(decades)) "all" else I(as.integer(decades))
        layers$species_decade$columns       <- list(
          cell = "cell_id", species = "aphiaid", count = "n", name_key = "name_key",
          year_min = "year_min", year_max = "year_max", period = "decade")
      }

      # the species table unpartitioned, one cell-sorted file per res, for the cell query ----
      if (length(res_species_flat)) {
        dir.create(file.path(out, "species_flat"), showWarnings = FALSE)
        rows_sf <- 0
        for (r in res_species_flat) {
          say("species flat res ", r, " ...")
          f <- file.path(out, "species_flat", paste0("res=", r, ".parquet"))
          rows_sf <- rows_sf + DBI::dbExecute(con, glue::glue(
            "COPY (SELECT h3, cell_id, name_key, aphiaid, n, year_min, year_max
                   FROM ({obis_h3_species_sql(r, lookup = lk)}) _f ORDER BY cell_id, aphiaid)
             TO '{q(f)}' (FORMAT PARQUET, COMPRESSION {compression}, ROW_GROUP_SIZE {row_group_rows});"))
        }
        layers$species_flat <- list(
          path          = "species_flat",
          partitions    = I(character(0)),
          template      = "species_flat/res=<res>.parquet",
          rows          = rows_sf,
          kind          = "species",
          href_template = "species_flat/res={res}.parquet",
          resolutions   = I(res_species_flat),
          sorted_by     = I(c("cell_id", "aphiaid")),
          row_group_rows = row_group_rows,
          columns       = list(cell = "cell_id", species = "aphiaid", count = "n", name_key = "name_key",
                               year_min = "year_min", year_max = "year_max"),
          note          = paste(
            "the species table of species/ in one file per res for every class, sorted by",
            "cell_id, aphiaid in row groups of row_group_rows: the species of a cell are the",
            "rows with cell_id BETWEEN the first and last descendant of the cell at this res",
            "(a range read of the overlapping row groups); join species/species.parquet on",
            "aphiaid for names"))
      }

      # the heads: Animalia and every taxon spanning two or more named classes, written
      # as taxon layers (taxon/rank=<rank>/taxon=<name>/res=<r>/) unless a layer serves them
      say("species heads ...")
      hd <- obis_h3_species_heads(con, lk, taxon_tbl)
      hd$layer_rank <- .obis_head_rank(hd$rank)
      hd$served_by  <- rep(NA_character_, nrow(hd))
      hd$layer      <- rep(NA_character_, nrow(hd))
      no_null <- DBI::dbGetQuery(con,
        "SELECT COUNT(*)::DOUBLE AS n FROM occ_h3 WHERE aphiaid IS NULL")$n == 0
      every <- hd$n_species == n_lookup & no_null
      hd$served_by[every] <- "all"
      hd$layer[every]     <- "all"
      if (has("idx_h3_taxon") && nrow(hd)) {
        tx  <- DBI::dbGetQuery(con, "SELECT DISTINCT rank, taxon FROM idx_h3_taxon")
        hit <- match(paste(hd$layer_rank, hd$name), paste(tx$rank, tx$taxon))
        use <- !is.na(hit) & is.na(hd$served_by)
        hd$served_by[use] <- "rank_layer"
        hd$layer[use] <- paste0("taxon/rank=", tx$rank[hit[use]], "/taxon=",
                                .obis_hive_value(tx$taxon[hit[use]]))
      }
      todo <- is.na(hd$served_by) & !is.na(hd$layer_rank) & !is.na(hd$name)
      homo <- todo & duplicated(paste(hd$layer_rank, hd$name))
      hd$served_by[homo] <- "homonym"
      todo <- todo & !homo
      n_built <- 0L
      if (heads && any(todo) && length(res_heads)) {
        hv <- "_export_heads_src"
        ht <- "_export_heads"
        hl <- "_export_heads_list"
        on.exit(DBI::dbExecute(con, glue::glue(
          "DROP TABLE IF EXISTS {ht}; DROP TABLE IF EXISTS {hl};")), add = TRUE)
        duckdb::duckdb_register(con, hv, data.frame(
          aphiaid = hd$aphiaid[todo], rank = hd$layer_rank[todo], taxon = hd$name[todo],
          stringsAsFactors = FALSE))
        DBI::dbExecute(con, glue::glue(
          "CREATE OR REPLACE TEMP TABLE {hl} AS
           SELECT aphiaid::BIGINT AS aphiaid, rank::VARCHAR AS rank, taxon::VARCHAR AS taxon FROM {hv}"))
        duckdb::duckdb_unregister(con, hv)
        for (i in seq_along(res_heads)) {
          say("heads res ", res_heads[i], " (", sum(todo), " taxa) ...")
          sql <- obis_h3_heads_sql(res_heads[i], hl, lk, esn = esn)
          DBI::dbExecute(con, if (i == 1L)
            glue::glue("CREATE OR REPLACE TEMP TABLE {ht} AS {sql}") else
            glue::glue("INSERT INTO {ht} {sql}"))
        }
        wl <- write_layer("taxon", "taxon", ht, c("rank", "taxon"), parent_res_taxon,
                          register = FALSE)
        if (is.null(layers$taxon)) {
          add_layer("taxon", "taxon", c("rank", "taxon", "res"), wl$rows, wl$pr_used)
        } else {
          layers$taxon$rows <- layers$taxon$rows + wl$rows
          if (length(wl$pr_used) && !length(layers$taxon$parent_res)) {
            layers$taxon$parent_res      <- as.list(wl$pr_used)
            layers$taxon$template_parent <- sub("/data_0.parquet$", "/p=<parent>/data_0.parquet",
                                                layers$taxon$template)
          } else if (length(wl$pr_used))
            layers$taxon$parent_res <- utils::modifyList(layers$taxon$parent_res, as.list(wl$pr_used))
        }
        got <- DBI::dbGetQuery(con, glue::glue("SELECT DISTINCT rank, taxon FROM {ht}"))
        ok  <- todo & paste(hd$layer_rank, hd$name) %in% paste(got$rank, got$taxon)
        hd$served_by[ok] <- "head"
        hd$layer[ok]     <- paste0("taxon/rank=", hd$layer_rank[ok], "/taxon=",
                                   .obis_hive_value(hd$name[ok]))
        n_built <- sum(ok)
        layers$taxon$heads <- list(
          n = n_built, res = I(res_heads), href = "species/heads.json",
          rows = wl$rows,
          note = paste(
            "the pre-aggregated heads (Animalia and the taxa spanning several classes) are",
            "taxon layers like the rank layers: rank is the WoRMS rank (kingdom, subphylum,",
            "superclass ...), values are the WoRMS subtree over the species lookup's lineage",
            "(obis_h3_heads_sql()); species/heads.json lists them"))
        DBI::dbExecute(con, glue::glue("DROP TABLE IF EXISTS {ht}; DROP TABLE IF EXISTS {hl};"))
      }
      n_heads <- nrow(hd)
      jsonlite::write_json(list(
        built    = n_built > 0,
        rule     = paste(
          "Animalia (aphiaid 2) and every taxon whose subtree spans two or more named",
          "classes (the lookup's OBIS class; NULL not counted). A subtree inside one",
          "class reads one class file plus class=_none; these taxa read many, so each",
          "is served by a pre-aggregated indicator layer: served_by 'head' is a taxon",
          "layer written from the WoRMS subtree (layer = its path), 'all' the all-taxa",
          "layer (the subtree holds every aphiaid), 'rank_layer' an existing rank layer",
          "built from the OBIS rank column (it may differ from the subtree in a few",
          "cells), 'homonym' a second taxon of the same rank and name (not written)."),
        existing = list(
          list(head = "all",    layer = "all"),
          list(head = "eov",    layer = "eov"),
          list(head = "phylum", layer = "taxon/rank=phylum"),
          list(head = "class",  layer = "taxon/rank=class"),
          list(head = "order",  layer = "taxon/rank=order"),
          list(head = "family", layer = "taxon/rank=family")),
        layer    = "taxon",
        res      = if (n_built > 0) I(res_heads) else I(integer(0)),
        n        = n_heads,
        n_built  = n_built,
        columns  = c(names(hd)),
        heads    = hd),
        file.path(out, "species", "heads.json"),
        auto_unbox = TRUE, pretty = TRUE, digits = NA, dataframe = "rows", na = "null")

      layers$species <- c(layers$species, list(
        kind          = "species",
        href_template = "species/res={res}/class={class}/data_0.parquet",
        resolutions   = I(res_species),
        partition_by  = I("class"),
        sorted_by     = I(c("cell_id", "aphiaid")),
        columns       = list(cell = "cell_id", species = "aphiaid", count = "n",
                             name_key = "name_key", year_min = "year_min", year_max = "year_max"),
        lookup        = list(
          href           = "species/species.parquet",
          key            = "aphiaid",
          lineage_column = "lineage",
          rank_columns   = list(phylum = "phylum", class = "class", order = "order",
                                family = "family", genus = "genus", species = "species"),
          name_column    = "species"),
        name_key      = list(
          column = "name_key",
          note   = paste(
            "richness (sp) counts distinct species names, as h3t does: count",
            "DISTINCT name_key (in the files and the lookup), not aphiaid; some",
            "names carry several aphiaids.")),
        null_class    = "_none",
        heads         = list(href = "species/heads.json", n = n_heads, built = n_built > 0,
                             n_built = n_built, layer = "taxon"),
        lookup_rows   = n_lookup,
        table_columns = SPECIES_COLUMNS,
        lookup_columns = SPECIES_LOOKUP_COLUMNS,
        note          = paste(
          "one row per (cell, aphiaid) with n = SUM(records) and year_min, year_max the first",
          "and last year recorded (NULL without a year), one data_0.parquet per",
          "(res, class), sorted by cell_id, aphiaid in row groups of 100k (ZSTD); res 4",
          "is rolled up from the res-5 occ_h3 tier. A NULL class is class=_none. A",
          "subtree is list_contains(lineage, <aphiaid>) on the lookup, joined on",
          "aphiaid; obis_h3_species_subtree_sql() writes the indicator query.")))
    } else say("skipping species: no aphiaid in occ_h3")
    DBI::dbExecute(con, glue::glue("DROP TABLE IF EXISTS {lk};"))
  } else if (length(res_species))
    say("skipping species: occ_h3 lacks ", paste(setdiff(sp_need, occ_cols), collapse = ", "))

  # stats.parquet: value ranges for colour ramps, read back from the files ----
  say("stats ...")
  # explicit hive types, so a taxon or EOV name is never auto-cast to a number
  hive_type <- c(res = "INTEGER", decade = "INTEGER", year = "INTEGER", eov = "VARCHAR",
                 rank = "VARCHAR", taxon = "VARCHAR", class = "VARCHAR")
  hive_type <- c(hive_type, p = "VARCHAR")
  rd <- function(sub, parts) glue::glue(
    "read_parquet('{q(file.path(out, sub))}{strrep('/*', length(parts))}/*.parquet', ",
    "hive_partitioning = true, hive_types = {{",
    "{paste(sprintf(\"'%s': '%s'\", parts, hive_type[parts]), collapse = ', ')}}})")
  # a layer's whole files, plus its parent partitions (one level deeper) if any
  has_files <- function(sub, depth) length(Sys.glob(file.path(
    out, sub, paste(rep("*", depth), collapse = "/"), "*.parquet"))) > 0
  rd_layer <- function(l, sel) {
    parts <- layers[[l]]$partitions
    src   <- character(0)
    if (has_files(layers[[l]]$path, length(parts)))
      src <- glue::glue("SELECT {sel} FROM {rd(layers[[l]]$path, parts)}")
    if (length(layers[[l]]$parent_res))
      src <- c(src, glue::glue("SELECT {sel} FROM {rd(layers[[l]]$path, c(parts, 'p'))}"))
    paste(src, collapse = "\nUNION ALL\n")
  }
  key_sql <- list(
    all        = "'' AS key, '' AS rank, NULL::INTEGER AS decade, NULL::INTEGER AS year",
    eov        = "eov AS key, '' AS rank, NULL::INTEGER AS decade, NULL::INTEGER AS year",
    taxon      = "taxon AS key, rank, NULL::INTEGER AS decade, NULL::INTEGER AS year",
    decade_all = "'' AS key, '' AS rank, decade, NULL::INTEGER AS year",
    decade_eov = "eov AS key, '' AS rank, decade, NULL::INTEGER AS year",
    year_all   = "'' AS key, '' AS rank, NULL::INTEGER AS decade, year",
    year_eov   = "eov AS key, '' AS rank, NULL::INTEGER AS decade, year")
  # the indicator layers with rows (the species layers have no indicators)
  live     <- names(layers)[vapply(layers, function(l)
    l$rows > 0 && is.null(l$kind), logical(1))]
  # one query per layer and variable, collected in R and written once: a single UNPIVOT over every
  # layer held all values in quantile_cont() states at once (not spillable) and, with the family
  # rank, outgrew a 24 GiB VM (killed 2026-10-12); per (layer, variable) the largest input is the
  # taxon layer's one column
  stats <- list()
  # (the place layer has no res: not in stats)
  for (l in intersect(live, names(key_sql))) for (v in EXPORT_VARS) {
    src <- rd_layer(l, glue::glue("'{l}' AS layer, {key_sql[[l]]}, res, '{v}' AS variable, {v}::DOUBLE AS value"))
    stats[[length(stats) + 1L]] <- DBI::dbGetQuery(con, glue::glue("
      SELECT layer, key, rank, decade, year, res, variable,
        MIN(value)                 AS min,
        quantile_cont(value, 0.02) AS p02,
        quantile_cont(value, 0.50) AS p50,
        quantile_cont(value, 0.98) AS p98,
        MAX(value)                 AS max,
        COUNT(value)               AS n_cells
      FROM ({src}) GROUP BY ALL"))
  }
  f_stats <- file.path(out, "stats.parquet")
  duckdb::duckdb_register(con, "export_stats", do.call(rbind, stats))
  on.exit(try(duckdb::duckdb_unregister(con, "export_stats"), silent = TRUE), add = TRUE)
  DBI::dbExecute(con, glue::glue("
    COPY (
      SELECT layer, key, rank, decade::INTEGER AS decade, year::INTEGER AS year,
             res::INTEGER AS res, variable,
             min, p02, p50, p98, max, n_cells::BIGINT AS n_cells
      FROM export_stats
      ORDER BY layer, key, rank, decade, year, res, variable
    ) TO '{q(f_stats)}' (FORMAT PARQUET, COMPRESSION {compression});"))
  duckdb::duckdb_unregister(con, "export_stats")

  # taxon_groups.parquet: what the app can offer, with paths ----
  say("taxon_groups ...")
  grp <- list()
  if ("taxon" %in% live) {
    g <- DBI::dbGetQuery(con, glue::glue(
      "SELECT 'taxon' AS kind, rank, taxon, taxon AS label,
              SUM(n)::DOUBLE AS n, COUNT(*)::INTEGER AS n_cells_res1
       FROM {rd('taxon', c('rank', 'taxon', 'res'))} WHERE res = 1 GROUP BY ALL ORDER BY rank, taxon"))
    # on-disk partition dirs, matched to their decoded taxon names
    dirs <- list.dirs(file.path(out, "taxon"), recursive = TRUE, full.names = FALSE)
    dirs <- dirs[grepl("^rank=[^/]+/taxon=[^/]+$", dirs)]
    key  <- paste(sub("^rank=([^/]+)/.*", "\\1", dirs),
                  vapply(sub(".*/taxon=", "", dirs), utils::URLdecode, character(1)),
                  sep = "\r")
    g$path <- if (nrow(g)) paste0("taxon/", dirs[match(paste(g$rank, g$taxon, sep = "\r"), key)]) else
      character(0)
    grp$taxon <- g
  }
  if ("eov" %in% live) {
    g <- DBI::dbGetQuery(con, glue::glue(
      "SELECT 'eov' AS kind, 'eov' AS rank, eov AS taxon,
              SUM(n)::DOUBLE AS n, COUNT(*)::INTEGER AS n_cells_res1
       FROM {rd('eov', c('eov', 'res'))} WHERE res = 1 GROUP BY ALL ORDER BY eov"))
    g$label <- unname(obis_eov_label(g$taxon))
    g$path  <- paste0("eov/eov=", g$taxon)
    grp$eov <- g[, c("kind", "rank", "taxon", "label", "n", "n_cells_res1", "path")]
  }
  f_groups <- file.path(out, "taxon_groups.parquet")
  if (length(grp)) {
    g <- do.call(rbind, unname(grp))
    g$url_path <- gsub("%", "%25", g$path, fixed = TRUE)
    duckdb::duckdb_register(con, "export_taxon_groups", g)
    on.exit(duckdb::duckdb_unregister(con, "export_taxon_groups"), add = TRUE)
    DBI::dbExecute(con, glue::glue(
      "COPY (SELECT * FROM export_taxon_groups) TO '{q(f_groups)}' ",
      "(FORMAT PARQUET, COMPRESSION {compression});"))
  } else {
    DBI::dbExecute(con, glue::glue(
      "COPY (SELECT NULL::VARCHAR AS kind, NULL::VARCHAR AS rank, NULL::VARCHAR AS taxon,
                    NULL::VARCHAR AS label, NULL::DOUBLE AS n, NULL::INTEGER AS n_cells_res1,
                    NULL::VARCHAR AS path, NULL::VARCHAR AS url_path WHERE false)
       TO '{q(f_groups)}' (FORMAT PARQUET, COMPRESSION {compression});"))
  }

  # file manifest + release.json ----
  files <- sort(list.files(out, pattern = "\\.parquet$", recursive = TRUE))
  meta  <- DBI::dbGetQuery(con, glue::glue(
    "SELECT file_name, num_rows FROM parquet_file_metadata('{q(out)}/**/*.parquet')
     UNION ALL
     SELECT file_name, num_rows FROM parquet_file_metadata('{q(out)}/*.parquet')"))
  meta$rel <- substring(normalizePath(meta$file_name), nchar(out) + 2L)
  manifest <- data.frame(
    path     = files,
    url_path = gsub("%", "%25", files, fixed = TRUE),
    rows     = as.numeric(meta$num_rows[match(files, meta$rel)]),
    bytes    = as.numeric(file.size(file.path(out, files))),
    stringsAsFactors = FALSE)
  manifest$parent <- ifelse(grepl("/p=[0-9a-f]+/", files),
                            sub(".*/p=([0-9a-f]+)/.*", "\\1", files), NA_character_)

  manifest$layer <- "meta"  # stats.parquet, taxon_groups.parquet
  for (l in names(layers))
    manifest$layer[startsWith(manifest$path, paste0(layers[[l]]$path, "/"))] <- l
  manifest$layer[manifest$path == "species/species.parquet"] <- "species_lookup"
  f_files <- file.path(out, "files.parquet")
  duckdb::duckdb_register(con, "export_files", manifest)
  on.exit(duckdb::duckdb_unregister(con, "export_files"), add = TRUE)
  DBI::dbExecute(con, glue::glue(
    "COPY (SELECT layer, path, url_path, rows::BIGINT AS rows, bytes::BIGINT AS bytes,
                  parent::VARCHAR AS parent
           FROM export_files ORDER BY path)
     TO '{q(f_files)}' (FORMAT PARQUET, COMPRESSION {compression});"))

  # the largest row group of an indicator layer file (DuckDB rounds row_group_rows up)
  ind_paths <- vapply(names(layers)[vapply(layers, function(l) is.null(l$kind), logical(1))],
                      function(l) layers[[l]]$path, "")
  ind_paths <- ind_paths[vapply(ind_paths, function(d)
    length(list.files(file.path(out, d), "\\.parquet$", recursive = TRUE)) > 0, logical(1))]
  ind_paths <- setdiff(ind_paths, c("place", "place_exact"))
  rg_max <- if (length(ind_paths)) DBI::dbGetQuery(con, paste(vapply(ind_paths, function(d) glue::glue(
    "SELECT MAX(row_group_num_rows)::DOUBLE AS m FROM parquet_metadata('{q(file.path(out, d))}/**/*.parquet')
     WHERE path_in_schema = 'cell_id'"), ""), collapse = " UNION ALL ")) else data.frame(m = NA_real_)
  rg_max <- suppressWarnings(max(rg_max$m, na.rm = TRUE))
  if (!is.finite(rg_max)) rg_max <- NA_real_

  store <- tryCatch(DBI::dbGetInfo(con)$dbname, error = function(e) NA_character_)
  snap  <- .obis_snapshot(release)
  for (l in names(layers)) {
    lf <- manifest[manifest$layer == l, ]
    layers[[l]]$rows  <- sum(lf$rows)
    layers[[l]]$files <- nrow(lf)
    layers[[l]]$bytes <- sum(lf$bytes)
  }
  if (!is.null(layers$species)) {
    # rows, files and bytes per resolution of the species table, and the lookup's size
    layers$species$by_res <- do.call(rbind, lapply(res_species, function(r) {
      lf <- manifest[startsWith(manifest$path, paste0("species/res=", r, "/")), ]
      data.frame(res = r, rows = sum(lf$rows), files = nrow(lf), bytes = sum(lf$bytes))
    }))
    layers$species$lookup_bytes <- manifest$bytes[manifest$layer == "species_lookup"]
  }
  info <- list(
    release                = release,
    # the OBIS data date: the newest object of s3://obis-open-data/occurrence/ the store was built
    # from (OBIS_DATA_DATE, set by refresh_obis_h3.sh), else the date in the release tag
    obis_snapshot          = snap,
    store                  = basename(store),
    obisindicators_version = .obisindicators_version(),
    # the WoRMS (ChecklistBank) version the store's taxonomy came from, when the refresh knows it
    worms_version          = Sys.getenv("OBIS_WORMS_VERSION"),
    duckdb_version         = DBI::dbGetQuery(con, "SELECT version() AS v")$v,
    built_at               = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    esn                    = esn,
    res                    = sort(DBI::dbGetQuery(con, "SELECT DISTINCT res FROM idx_h3")$res),
    res_decade             = I(res_decade),
    decades                = if (is.null(decades)) "all" else I(as.integer(decades)),
    res_year               = I(res_year),
    # the years with files (every year present from min(date_year) to max, or those requested)
    years                  = I(yrs_out),
    year_range             = if (is.na(yr_rng$lo)) I(integer(0)) else I(c(yr_rng$lo, yr_rng$hi)),
    res_species            = I(res_species),
    species_decades        = species_decades,
    compression            = compression,
    # every indicator layer file is sorted by cell_id in row groups of at most row_group_rows_max rows
    sorted_by              = "cell_id",
    row_group_rows         = row_group_rows,
    row_group_rows_max     = rg_max,
    layers                 = layers,
    columns                = EXPORT_COLUMNS,
    stats = list(
      file    = "stats.parquet",
      columns = c("layer", "key", "rank", "decade", "year", "res", "variable",
                  "min", "p02", "p50", "p98", "max", "n_cells"),
      note    = "one row per indicator layer x key x decade x year x res x variable; n_cells counts cells with a non-NULL value (0 when all are NULL, e.g. es where every n < 50)"),
    taxon_groups = list(
      file    = "taxon_groups.parquet",
      columns = c("kind", "rank", "taxon", "label", "n", "n_cells_res1", "path", "url_path")),
    encoding = paste(
      "partition values are percent-encoded on disk by DuckDB (space = %20);",
      "fetch over HTTP with `url_path` (each % encoded as %25), or read with",
      "DuckDB hive_partitioning, which decodes them."),
    decade_note = paste(
      "decade = floor(date_year / 10) * 10; records with no year are excluded;",
      "indicators computed with the same SQL as idx_h3 / idx_h3_eov."),
    year_note = paste(
      "year = date_year; records with no year are excluded; one partition per year",
      "present between min(date_year) and max(date_year) (or the requested years),",
      "listed in `years`; indicators computed with the same SQL as idx_h3 / idx_h3_eov",
      "and the decade layers; never split by parent cell."),
    files = list(
      file    = "files.parquet",
      columns = c("layer", "path", "url_path", "rows", "bytes", "parent"),
      n_files = nrow(manifest) + 1L,
      note    = "manifest of every parquet file except itself (HTTP cannot glob)"),
    parents = list(
      parent_res       = as.list(parent_res),
      parent_res_taxon = as.list(parent_res_taxon),
      parent_min_rows  = parent_min_rows,
      note = paste(
        "a layer's resolutions listed in its `parent_res` are split one file per",
        "parent cell, <layer path>/.../res=<r>/p=<parent h3>/data_0.parquet, for",
        "every (layer key, res) with more than parent_min_rows rows (others stay",
        "whole); files.parquet `parent` is that parent cell (NULL for a whole",
        "file), and its H3 resolution is the parent resolution. A viewer loads",
        "the parents covering its viewport.")))
  if (!nzchar(info$worms_version)) info$worms_version <- NULL   # unknown: left out, not ""
  f_json <- file.path(out, "release.json")
  jsonlite::write_json(info, f_json, auto_unbox = TRUE, pretty = TRUE,
                       digits = NA, dataframe = "rows")
  f_stac  <- obis_h3_stac_collection(out)
  f_heads <- file.path(out, "species", "heads.json")
  f_heads <- f_heads[file.exists(f_heads)]

  # summary ----
  if (verbose) {
    mb <- function(b) sprintf("%.1f MB", b / 1e6)
    message("exported ", out, " in ",
            format(round(difftime(Sys.time(), t0, units = "mins"), 1)))
    for (l in names(layers))
      message(sprintf("  %-11s %12s rows %6d files %10s", l,
                      format(layers[[l]]$rows, big.mark = ","),
                      layers[[l]]$files, mb(layers[[l]]$bytes)))
    if (!is.null(layers$species)) {
      message("  species by res (rows, files, bytes); heads: ", layers$species$heads$n_built,
              " of ", n_heads, " written as taxon layers")
      for (i in seq_len(nrow(layers$species$by_res)))
        with(layers$species$by_res[i, ], message(sprintf(
          "    res %d %12s rows %6d files %10s", res, format(rows, big.mark = ","), files, mb(bytes))))
    }
    message(sprintf("  total       %6d files %10s", nrow(manifest) + 3L + length(f_heads),
                    mb(sum(manifest$bytes) + sum(file.size(c(f_json, f_files, f_stac, f_heads))))))
  }
  invisible(c(f_json, f_files, f_stac, f_heads, file.path(out, manifest$path)))
}

# release.json's obis_snapshot: the OBIS data date when known (the newest object of
# s3://obis-open-data/occurrence/, as refresh_obis_h3.sh reads it off the synced files), else the
# date in a vYYYYMMDD release tag, else the tag itself
.obis_snapshot <- function(release, data_date = Sys.getenv("OBIS_DATA_DATE")) {
  if (grepl("^\\d{4}-\\d{2}-\\d{2}$", data_date)) return(data_date)
  if (grepl("^v?\\d{8}$", release)) {
    d <- sub("^v", "", release)
    return(paste(substr(d, 1, 4), substr(d, 5, 6), substr(d, 7, 8), sep = "-"))
  }
  release
}

# the obisindicators version for release.json: the checkout's DESCRIPTION when the code was sourced
# from one (OBIS_PKG_ROOT, as the monthly refresh does inside its image, which does not install the
# package), else the installed package's; NA when neither is available
.obisindicators_version <- function(pkg_root = Sys.getenv("OBIS_PKG_ROOT")) {
  f <- file.path(pkg_root, "DESCRIPTION")
  if (nzchar(pkg_root) && file.exists(f)) {
    d <- read.dcf(f, fields = c("Package", "Version"))
    if (identical(unname(d[1, "Package"]), "obisindicators")) return(unname(d[1, "Version"]))
  }
  tryCatch(as.character(utils::packageVersion("obisindicators")), error = function(e) NA_character_)
}

#' SQL for the per-year indicator layers
#'
#' The indicators of one resolution per year (and per EOV), computed from
#' `occ_h3` with the store's indicator SQL (the same `.h3t_indicators_sql()`
#' that builds `idx_h3`, `idx_h3_eov` and the decade layers): `n` = records,
#' `sp` = distinct species names, Shannon, Simpson and ES(`esn`), grouped by
#' cell and `year = CAST(date_year AS INTEGER)`. Records without a year are left
#' out. The cells come from the coarsest `occ_h3` tier at least as fine as
#' `res` (res 4 is rolled up from the res-5 tier). EOV membership is the
#' store's `eov` table (`occ_h3.aphiaid = eov.taxonID`).
#'
#' @param res H3 resolution, 1 to 7.
#' @param eov per EOV as well (needs the `eov` table; default FALSE).
#' @param years years to keep (default NULL: every year present).
#' @param esn expected sample size for ES(n) (default 50).
#' @param from the species-level table (default `"occ_h3"`).
#' @return a SQL string with columns `[eov,] year, res, h3, cell_id, n, sp,
#'   shannon, simpson, es`.
#' @concept store
#' @export
#' @examples
#' cat(obis_h3_year_sql(4))
obis_h3_year_sql <- function(res, eov = FALSE, years = NULL, esn = 50L, from = "occ_h3") {
  .obis_h3_period_sql(res, "year", eov = eov, periods = years, esn = esn, from = from)
}

# the per-period (decade or year) indicator SQL of the export's decade and year layers
.obis_h3_period_sql <- function(res, period = c("decade", "year"), eov = FALSE, periods = NULL,
                                esn = 50L, from = "occ_h3") {
  period <- match.arg(period)
  res    <- as.integer(res)
  stopifnot(length(res) == 1L, res %in% H3T_RES_IDX, is.logical(eov), length(eov) == 1L)
  tier <- .obis_tier(res)  # coarsest occ_h3 tier at least as fine as res
  p    <- if (eov) "o." else ""
  pexp <- switch(period,
    decade = glue::glue("CAST(floor({p}date_year / 10) * 10 AS INTEGER)"),
    year   = glue::glue("CAST({p}date_year AS INTEGER)"))
  filt <- if (is.null(periods)) "" else glue::glue(
    " AND {pexp} IN ({paste(as.integer(periods), collapse = ', ')})")
  cols <- "lower(printf('%x', cell_id)) AS h3, cell_id, n, sp, shannon, simpson, es"
  if (!eov) {
    src <- glue::glue("
      SELECT {pexp} AS {period},
             CAST(h3_cell_to_parent(cell_id, {res}) AS BIGINT) AS cell_id,
             species, SUM(records) AS ni
      FROM {from}
      WHERE res = {tier} AND date_year IS NOT NULL{filt}
      GROUP BY 1, 2, 3")
    keys <- period
  } else {
    src <- glue::glue("
      SELECT e.eov, {pexp} AS {period},
             CAST(h3_cell_to_parent(o.cell_id, {res}) AS BIGINT) AS cell_id,
             o.species, SUM(o.records) AS ni
      FROM {from} o
      JOIN eov e ON o.aphiaid = e.taxonID
      WHERE o.res = {tier} AND o.date_year IS NOT NULL{filt}
      GROUP BY 1, 2, 3, 4")
    keys <- c("eov", period)
  }
  ind <- .h3t_indicators_sql(src, keys = keys, esn = as.integer(esn))
  glue::glue("SELECT {paste(keys, collapse = ', ')}, {res}::UTINYINT AS res, {cols} FROM ({ind}) _d")
}

# the Parquet types of the indicator columns (the `all` layer's files)
EXPORT_COLUMN_TYPES <- c(h3 = "VARCHAR", cell_id = "BIGINT", n = "BIGINT", sp = "BIGINT",
                         shannon = "DOUBLE", simpson = "DOUBLE", es = "DOUBLE")

# the URI of the Ocean Metrics h3 STAC profile (its $id)
OM_H3_PROFILE <- "https://oceanmetrics.io/schemas/h3/v1.0.0/schema.json"

#' Write the STAC Collection of an obis-h3 release
#'
#' Reads a release's `release.json` (from [obis_h3_export_parquet()]) and
#' writes `collection.json`, a STAC Collection for the Ocean Metrics `h3`
#' profile (`platform/packages/catalog/schemas/h3.schema.json`): the
#' resolutions, the `all` layer's path template with its parent splits
#' (`h3:layout`), the indicator columns (`table:columns`) and, when the release
#' has one, the species table (`h3:species_table`: its template, resolutions,
#' class partitions, sort, columns and lookup). The profile's fields describe
#' the `all` layer; the other layers (EOV, taxon, decade, year) and the heads
#' list are in pass-through keys, `obis:layers` (each with a `{key}` template,
#' and `h3:periods` for the decade and year layers) and `obis:species`
#' (`name_key`, `null_class`, `heads`), which the profile allows.
#'
#' @param release_dir the release directory (holding `release.json`).
#' @param file output file (default `collection.json` in `release_dir`).
#' @param id the collection id (default `"obis-h3"`).
#' @return invisibly, the path written.
#' @concept store
#' @export
obis_h3_stac_collection <- function(release_dir, file = file.path(release_dir, "collection.json"),
                                    id = "obis-h3") {
  stopifnot(requireNamespace("jsonlite", quietly = TRUE))
  js <- jsonlite::read_json(file.path(release_dir, "release.json"))
  tpl <- function(x) gsub("<([A-Za-z_]+)>", "{\\1}", x)  # release.json <key> -> STAC {key}
  ints <- function(x) as.integer(unlist(x))

  all <- js$layers$all
  layout <- list(template = tpl(all$template))
  if (length(all$parent_res)) {
    layout$parent_template <- tpl(all$template_parent)
    layout$parent_res      <- lapply(all$parent_res, as.integer)
  }

  # every layer, as a template with {key} placeholders
  obis_layers <- lapply(names(js$layers), function(l) {
    x <- js$layers[[l]]
    o <- list(template = tpl(x$template), keys = I(as.character(unlist(x$partitions))),
              rows = x$rows, files = x$files, bytes = x$bytes)
    if (length(x$parent_res)) {
      o$parent_template <- tpl(x$template_parent)
      o$parent_res      <- lapply(x$parent_res, as.integer)
    }
    if (l %in% c("decade_all", "decade_eov") && is.list(js$decades))
      o$`h3:periods` <- list(grain = "decade", values = I(as.character(ints(js$decades))),
                             placeholder = "decade")
    if (l %in% c("year_all", "year_eov") && length(js$years))
      o$`h3:periods` <- list(grain = "year", values = I(as.character(ints(js$years))),
                             placeholder = "year")
    o
  })
  names(obis_layers) <- names(js$layers)

  yr <- ints(js$year_range)
  t0 <- if (length(yr) == 2L) sprintf("%04d-01-01T00:00:00Z", yr[1]) else NULL
  snap <- if (is.null(js$obis_snapshot)) "" else js$obis_snapshot
  t1 <- if (grepl("^\\d{4}-\\d{2}-\\d{2}$", snap))
    paste0(js$obis_snapshot, "T00:00:00Z") else NULL

  col <- list(
    type            = "Collection",
    stac_version    = "1.1.0",
    stac_extensions = I(c(OM_H3_PROFILE, "https://stac-extensions.github.io/table/v1.2.0/schema.json")),
    id              = id,
    title           = "OBIS biodiversity indicators on H3",
    description     = paste(
      "Records, species richness, Shannon, Simpson and ES(50) per H3 cell from the",
      "Ocean Biodiversity Information System (OBIS) snapshot", snap,
      paste0("(release ", js$release, "),"), "for all taxa, Essential Ocean Variables, taxa",
      "(phylum to family), decades and years, with the species x hex x count table."),
    license         = "other",
    extent          = list(
      spatial  = list(bbox = list(c(-180, -90, 180, 90))),
      temporal = list(interval = list(list(t0, t1)))),
    links = list(
      list(rel = "self",    href = "./collection.json", type = "application/json"),
      list(rel = "related", href = "./release.json",    type = "application/json",
           title = "release metadata: layers, row counts, columns, notes")),
    `h3:resolutions` = I(ints(js$res)),
    `h3:cell_column` = "h3",
    `h3:cell_type`   = "string",
    `h3:layout`      = layout,
    `table:columns`  = lapply(names(EXPORT_COLUMN_TYPES), function(k) list(
      name = k, type = unname(EXPORT_COLUMN_TYPES[k]), description = js$columns[[k]])),
    `obis:release`   = js$release,
    `obis:layers`    = obis_layers,
    assets = list(
      release = list(href = "./release.json", type = "application/json",
                     title = "release metadata", roles = I("metadata")),
      files   = list(href = "./files.parquet", type = "application/vnd.apache.parquet",
                     title = "file manifest", roles = I("metadata")),
      stats   = list(href = "./stats.parquet", type = "application/vnd.apache.parquet",
                     title = "value ranges per layer, key, period, res and variable",
                     roles = I("metadata")),
      taxon_groups = list(href = "./taxon_groups.parquet", type = "application/vnd.apache.parquet",
                          title = "taxa and EOVs with totals and paths", roles = I("metadata"))))
  if (is.null(t0) && is.null(t1))
    col$extent$temporal$interval <- list(list(NULL, NULL))

  sp <- js$layers$species
  if (!is.null(sp)) {
    col$`h3:species_table` <- list(
      href_template = sp$href_template,
      resolutions   = I(ints(sp$resolutions)),
      partition_by  = I(unlist(sp$partition_by)),
      sorted_by     = I(unlist(sp$sorted_by)),
      columns       = sp$columns,
      lookup        = sp$lookup)
    col$`obis:species` <- list(
      name_key   = sp$name_key,
      null_class = sp$null_class,
      heads      = sp$heads,
      columns    = sp$table_columns,
      lookup_columns = sp$lookup_columns)
    col$assets$species_lookup <- list(
      href = paste0("./", sp$lookup$href), type = "application/vnd.apache.parquet",
      title = "species lookup: names, name_key, lineage", roles = I("metadata"))
    col$assets$species_heads <- list(
      href = paste0("./", sp$heads$href), type = "application/json",
      title = "pre-aggregated heads still to build", roles = I("metadata"))
  }
  jsonlite::write_json(col, file, auto_unbox = TRUE, pretty = TRUE, digits = NA, null = "null")
  invisible(file)
}
