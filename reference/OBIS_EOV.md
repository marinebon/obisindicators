# The IOOS Marine Life Data Network EOV definitions

Root WoRMS AphiaIDs per Essential Ocean Variable, transcribed from
[ioos/marine_life_data_network](https://github.com/ioos/marine_life_data_network/tree/main/eov_taxonomy)
`eov_taxonomy/IdentifierList.csv`. Each EOV is the union of the
descendant subtrees of its seeds. Accessed through
[`obis_eov_seeds()`](https://marinebon.org/obisindicators/reference/obis_eov_seeds.md).

## Usage

``` r
OBIS_EOV
```

## Format

a named list; each element has `label`, `aphiaid`, and `taxon` (the seed
scientific names, in the same order as `aphiaid`).
