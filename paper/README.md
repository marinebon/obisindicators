# paper/ — figures and case studies for the OBIS → H3 → EOV manuscript

Each notebook produces one figure/table of the manuscript by calling exported,
tested functions of `obisindicators` (no analysis logic lives in the notebooks).
Outputs land in `figures/` as PNG + the CSV behind each plot.

| notebook | manuscript item | functions |
|---|---|---|
| `01_store-stats.qmd` | Table 2 (store), Table 5 (benchmarks) | `obis_store_stats()`, `obis_bench()`, `obis_bench_queries()` |
| `02_rank-vs-subtree.qmd` | Table 3 | `calc_rank_vs_subtree()`, `obis_rank_presets()` |
| `03_eov-totals.qmd` | Table 4 + Fig. 1 (gap-fill / seagrasses) | `calc_eov_totals()`, `compare_eov_totals()`, `obis_taxon_orphans()`, `gmap_cells()` |
| `04_eov-maps.qmd` | Fig. 2 (seven EOVs: records, ES50, coverage) | `obis_cell_indicators()`, `gmap_cells()` |
| `05_scale-curves.qmd` | Fig. 3 | `calc_scale_curves()`, `calc_spue_scale()`, `plot_scale_curves()` |
| `06_spue-sdm.qmd` | Fig. 4 | `calc_spue_cells()`, `h3_raster_to_cells()`, `compare_spue_sdm()`, `plot_spue_sdm()` |
| `07_decadal.qmd` | Fig. 5 | `calc_period_indicators()`, `calc_period_change()` |
| `08_place-rollups.qmd` | Fig. 6 | `place_cells()`, `calc_place_indicators()` |

## Run

```bash
# 1. point at a store (the global one on the MST server, or a regional demo)
export OBIS_H3_DUCKDB=~/_big/obis_h3_demo_gulf.duckdb
#    build the demo (Gulf of Mexico + Caribbean, ~8M records) from a local OBIS
#    export + WoRMS table; add --fill to close the taxonomy gap via WoRMS REST
Rscript paper/build_demo_store.R                 # ~10 min

# 2. optional inputs
export SDM_TIF=/path/to/suitability.tif          # 06_spue-sdm.qmd (else skipped)
export PLACES_GPKG=/path/to/places.gpkg          # 08_place-rollups.qmd (else onmsR sanctuaries / bbox demo)
export OBIS_H3_DUCKDB_BEFORE=/path/pre-gapfill.duckdb   # 03_eov-totals.qmd before/after

# 3. render one or all
cd paper && quarto render 05_scale-curves.qmd
cd paper && quarto render
```

Numbers in the manuscript come from the **global** store
(`/share/data/obis/obis_h3.duckdb` on the MST server); the demo store is for
developing figures and for the WG to poke at locally.
