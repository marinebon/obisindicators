# This file is used to generate subsets of data from the full OBIS .parquet export.
# This file will take a long time to run, so press go and go get a snack.
#
# occ ----
librarian::shelf(
  arrow, dplyr, here, readr)

# obis_20220404.parquet downloaded from https://obis.org/data/access on 2022-04-26
occ <- open_dataset("../../obis_20220404.parquet")

# NOTE: there are lots of other fields in the parquet file.
#     These could be used in the future.
trimmed_occ <- select(occ, decimalLongitude, decimalLatitude, species, date_year) # drop unnecessary columns
grouped_occ <- group_by(trimmed_occ, decimalLongitude, decimalLatitude, species, date_year) %>%  # remove dulplicate rows
  filter(!is.na(species))  %>%
  collect() %>%
  summarize(records = n()) %>%
  ungroup()

# occ_1M, subsampled global occurrence dataset ----
set.seed(42)
i <- sample(1:nrow(occ), 1000000)
occ_1M <- slice(grouped_occ, i)
usethis::use_data(occ_1M, overwrite=TRUE)

# occ_SAtlantic,full regional occurrence dataset ----
# Southern Ocean chosen since somewhat sparsely populated and provides a latitudinal gradient
# [Marine Regions · South Atlantic Ocean (IHO Sea Area)](https://marineregions.org/gazetteer.php?p=details&id=1914)
occ_SAtlantic <- grouped_occ %>%
  filter(
    decimalLatitude  >= -60     , decimalLatitude  <= 0.0751,
    decimalLongitude >= -69.6008, decimalLongitude <= 20.0091) # 1,014,006 × 4
usethis::use_data(occ_SAtlantic, overwrite=TRUE)

# occ_fk,full regional occurrence dataset ----
# Tiny section around the FL keys
occ_fk <- grouped_occ %>%
  filter(
    decimalLatitude <= -70,
    decimalLatitude >= -90,
    decimalLongitude >= 20,
    decimalLongitude <= 30)
usethis::use_data(occ_fk, overwrite=TRUE)

# time series ----
oc_ts <- c(
    filter(
      grouped_occ,
      date_year <= 2020,
      date_year >= 2010
    ),
    filter(
      grouped_occ,
      date_year <= 2010,
      date_year >= 2000
    ),
    filter(
      grouped_occ,
      date_year <= 2000,
      date_year >= 1990
    ),
    filter(
      grouped_occ,
      date_year <= 1990,
      date_year >= 1980
    ),
    filter(
      grouped_occ,
      date_year <= 1980,
      date_year >= 1970
    ),
    filter(
      grouped_occ,
      date_year <= 1980,
      date_year >= 1970
    ),
    filter(
      grouped_occ,
      date_year <= 1970,
      date_year >= 1960
    )
)

min_n_samples <- min(oc_ts)

usethis::use_data(occ_2010s, overwrite=TRUE)
usethis::use_data(occ_2000s, overwrite=TRUE)
usethis::use_data(occ_1990s, overwrite=TRUE)
usethis::use_data(occ_1980s, overwrite=TRUE)
usethis::use_data(occ_1970s, overwrite=TRUE)
usethis::use_data(occ_1960s, overwrite=TRUE)

