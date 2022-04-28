# This file is used to generate subsets of data from the full OBIS .parquet export.
# This file will take a long time to run, so press go and go get a snack.
#
# occ ----
librarian::shelf(
  arrow, dplyr, here, readr)

# obis_20220404.parquet downloaded from https://obis.org/data/access on 2022-04-26
#   NOTE: .gitignore prevents this large file from being on Github
occ_all <- open_dataset(here("data-raw/obis_20220404.parquet"))
# NOTE: there are lots of other fields in the parquet file.
#     These could be used in the future.
occ <- occ_all %>%
  group_by(
    decimalLongitude, decimalLatitude, species, date_year) %>%  # remove dulplicate rows
  filter(!is.na(species))  %>%
  summarize(
    records = n(),
    .groups = "drop") %>%
  collect()

# occ_1M: subsampled global occurrence dataset ----
set.seed(42)
i <- sample(1:nrow(occ), 1000000)
occ_1M <- slice(occ, i)
usethis::use_data(occ_1M, overwrite=TRUE)

# occ_SAtlantic: South Atlantic regional occurrences ----
# Southern Ocean chosen since somewhat sparsely populated and provides a latitudinal gradient
# [Marine Regions · South Atlantic Ocean (IHO Sea Area)](https://marineregions.org/gazetteer.php?p=details&id=1914)
occ_SAtlantic <- occ %>%
  filter(
    decimalLatitude  >= -60     , decimalLatitude  <= 0.0751,
    decimalLongitude >= -69.6008, decimalLongitude <= 20.0091) # 1,014,006 × 4
usethis::use_data(occ_SAtlantic, overwrite=TRUE)

# occ_fk: Florida Keys regional occurrences ----
# Tiny section around the FL keys
occ_fk <- occ %>%
  filter(
    decimalLatitude <= -70,
    decimalLatitude >= -90,
    decimalLongitude >= 20,
    decimalLongitude <= 30)
usethis::use_data(occ_fk, overwrite=TRUE)

# time series ----

# helper function to limit the records to 1 million
limit_n <- function(d, n = 1000000){
  if (nrow(d) > n)
    return(sample_n(d, n))
  d
}

occ_2010s <- occ %>%
  filter(
    date_year <= 2020,
    date_year >= 2010) %>%
  limit_n()
usethis::use_data(occ_2010s, overwrite=TRUE)

occ_2000s <- occ %>%
  filter(
    date_year <= 2010,
    date_year >= 2000) %>%
  limit_n()
usethis::use_data(occ_2000s, overwrite=TRUE)

occ_1990s <- occ %>%
  filter(
    date_year <= 2000,
    date_year >= 1990) %>%
  limit_n()
usethis::use_data(occ_1990s, overwrite=TRUE)

occ_1980s <- occ %>%
  filter(
    date_year <= 1990,
    date_year >= 1980) %>%
  limit_n()
usethis::use_data(occ_1980s, overwrite=TRUE)

occ_1970s <- occ %>%
  filter(
    date_year <= 1980,
    date_year >= 1970) %>%
  limit_n()
usethis::use_data(occ_1970s, overwrite=TRUE)

occ_1960s <- occ %>%
  filter(
    date_year <= 1970,
    date_year >= 1960) %>%
  limit_n()
usethis::use_data(occ_1960s, overwrite=TRUE)
