# Essential Ocean Variable (EOV) taxonomic seeds

The root WoRMS AphiaIDs defining each biology & ecosystems EOV, per the
IOOS Marine Life Data Network. Expand them to occurrences with
[`obis_eov_sql()`](https://marinebon.org/obisindicators/reference/obis_eov_sql.md),
or to their descendant taxa with
[`obis_taxon_children()`](https://marinebon.org/obisindicators/reference/obis_taxon_children.md).

## Usage

``` r
obis_eov_seeds(eov = NULL)
```

## Arguments

- eov:

  optional EOV name(s) to restrict to; default all. One or more of
  `"fish"`, `"hardCorals"`, `"mangroves"`, `"marineMammals"`,
  `"seabirds"`, `"seagrasses"`, `"seaTurtles"`.

## Value

data frame with one row per seed taxon: `eov`, `label`, `desc`,
`aphiaid`, `taxon`, `rank`.

## Examples

``` r
head(obis_eov_seeds())
#>          eov       label
#> 1       fish        Fish
#> 2       fish        Fish
#> 3       fish        Fish
#> 4 hardCorals Hard corals
#> 5  mangroves   Mangroves
#> 6  mangroves   Mangroves
#>                                                                          desc
#> 1                                All fishes: jawless, cartilaginous and bony.
#> 2                                All fishes: jawless, cartilaginous and bony.
#> 3                                All fishes: jawless, cartilaginous and bony.
#> 4                                                 Reef-building stony corals.
#> 5 Mangrove trees, shrubs and the mangrove fern, as 19 genera plus one family.
#> 6 Mangrove trees, shrubs and the mangrove fern, as 19 genera plus one family.
#>   aphiaid          taxon        rank
#> 1    1829        Agnatha Infraphylum
#> 2 1517375 Chondrichthyes  Parvphylum
#> 3  152352   Osteichthyes  Parvphylum
#> 4    1363   Scleractinia       Order
#> 5  235048   Combretaceae      Family
#> 6  235033      Avicennia       Genus
obis_eov_seeds("seaTurtles")
#>          eov       label            desc aphiaid        taxon        rank
#> 1 seaTurtles Sea turtles Marine turtles.  987094 Chelonioidea Superfamily
```
