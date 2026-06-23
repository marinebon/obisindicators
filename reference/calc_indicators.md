# Calculate Biodiversity Indicators, including ES50 (Hurlbert index)

Calculate the expected number of marine species in a random sample of 50
individuals (records)

## Usage

``` r
calc_indicators(df, esn = 50)
```

## Arguments

- df:

  data frame with unique species observations containing columns:
  `cell`, `species`, `records`

- esn:

  expected number of marine species

## Value

Data frame with the following extra columns:

- `n`: number of records

- `sp`: species richness

- `shannon`: Shannon index

- `simpson`: Simpson index

- `es`: Hurlbert index (n = 50), i.e. expected species from 50 samples
  ES(50)

- `hill_1`: Hill number `exp(shannon)`

- `hill_2`: Hill number `1/simpson`

- `hill_inf`: Hill number `1/maxp`

## Details

The expected number of marine species in a random sample of 50
individuals (records) is an indicator on marine biodiversity richness.
The ES50 is defined in OBIS as the `sum(esi)` over all species of the
following per species calculation:

- when \`n - ni \>= 50 (with n as the total number of records in the
  cell and ni the total number of records for the ith-species)

  - `esi = 1 - exp(lngamma(n-ni+1) + lngamma(n-50+1) - lngamma(n-ni-50+1) - lngamma(n+1))`

- when `n >= 50` - `esi = 1`

- else - `esi = NULL`

Warning: ES50 assumes that individuals are randomly distributed, the
sample size is sufficiently large, the samples are taxonomically
similar, and that all of the samples have been taken in the same manner.
