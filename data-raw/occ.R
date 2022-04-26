# occ ----
librarian::shelf(
  arrow, dplyr, here, readr)

# obis_20220404.parquet downloaded from https://obis.org/data/access on 2022-04-26
occ <- open_dataset(here("data/obis_20220404.parquet"))
occ <- occ %>%
  select(decimalLongitude, decimalLatitude, species) %>%
  group_by(decimalLongitude, decimalLatitude, species) %>%
  collect() %>%
  summarize(records = n()) %>%
  ungroup()

# occ_1M, subsampled global occurrence dataset ----
set.seed(42)
i <- sample(1:nrow(occ), 1000000)
occ_1M <- slice(pcc, i)
usethis::use_data(occ_1M)

# occ_SAtlantic,full regional occurrence dataset ----
# Southern Ocean chosen since somewhat sparsely populated and provides a latitudinal gradient
# [Marine Regions · South Atlantic Ocean (IHO Sea Area)](https://marineregions.org/gazetteer.php?p=details&id=1914)
occ_SAtlantic <- occ %>%
  filter(
    decimalLatitude  >= -60     , decimalLatitude  <= 0.0751,
    decimalLongitude >= -69.6008, decimalLongitude <= 20.0091) # 1,014,006 × 4
usethis::use_data(occ_SAtlantic)
