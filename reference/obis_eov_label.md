# Human-readable EOV label with its taxonomic definition

A compact "what is this, taxonomically" string for pickers and legends,
e.g. `"Sea turtles (superfamily Chelonioidea)"`. Lives in the package
rather than the consuming app so a label can never drift from the seeds
it describes.

## Usage

``` r
obis_eov_label(eov = NULL, max_taxa = 3L)
```

## Arguments

- eov:

  EOV name(s); see
  [`obis_eov_seeds()`](https://marinebon.org/obisindicators/reference/obis_eov_seeds.md).

- max_taxa:

  list seed names up to this many, then summarise as a count.

## Value

character vector, one label per EOV, named by EOV.

## Details

One seed renders as `rank Name`; a few render as a name list; many
collapse to a count, since a picker cannot usefully show 19 mangrove
genera.

## Examples

``` r
obis_eov_label()
#>                                                     fish 
#>           "Fish (Agnatha, Chondrichthyes, Osteichthyes)" 
#>                                               hardCorals 
#>                       "Hard corals (order Scleractinia)" 
#>                                                mangroves 
#>                 "Mangroves (19 seed taxa: family/genus)" 
#>                                            marineMammals 
#> "Marine mammals (7 seed taxa: infraorder/order/species)" 
#>                                                 seabirds 
#>                                  "Seabirds (class Aves)" 
#>                                               seagrasses 
#>                         "Seagrasses (order Alismatales)" 
#>                                               seaTurtles 
#>                 "Sea turtles (superfamily Chelonioidea)" 
```
