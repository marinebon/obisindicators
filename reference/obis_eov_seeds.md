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

data frame with one row per seed taxon: `eov`, `label`, `aphiaid`,
`taxon`.

## Examples

``` r
head(obis_eov_seeds())
#>          eov       label aphiaid          taxon
#> 1       fish        Fish    1829        Agnatha
#> 2       fish        Fish 1517375 Chondrichthyes
#> 3       fish        Fish  152352   Osteichthyes
#> 4 hardCorals Hard corals    1363   Scleractinia
#> 5  mangroves   Mangroves  235048   Combretaceae
#> 6  mangroves   Mangroves  235033      Avicennia
obis_eov_seeds("seaTurtles")
#>          eov       label aphiaid        taxon
#> 1 seaTurtles Sea turtles  987094 Chelonioidea
```
