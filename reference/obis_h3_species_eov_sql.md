# SQL for the EOV of each species, as the EOV layers count it

The EOV layers (`eov/`, `decade/eov/`, `year/eov/`, `idx_h3_eov`) count
an occurrence in an EOV when `occ_h3.aphiaid = eov.taxonID`, the store's
`eov` table holding each EOV's IOOS seeds expanded down the WoRMS taxon
tree
([`obis_eov_bake()`](https://marinebon.org/obisindicators/reference/obis_eov_bake.md)).
The species lookup's `eov` is that same join: the one EOV whose
membership holds the aphiaid, or NULL. The seeds (Agnatha,
Chondrichthyes, Osteichthyes; Scleractinia; the mangrove genera;
Pinnipedia, Cetacea, Sirenia and four species; Aves; Alismatales;
Chelonioidea) are disjoint subtrees of one tree, so an aphiaid is in at
most one EOV; `n_eov` says how many hold it, and
[`obis_h3_write_species_lookup()`](https://marinebon.org/obisindicators/reference/obis_h3_write_species_lookup.md)
stops when any holds more than one rather than pick.

## Usage

``` r
obis_h3_species_eov_sql(eov = "eov")
```

## Arguments

- eov:

  the membership table (default `"eov"`, columns `eov`, `taxonID`).

## Value

a SQL string (a SELECT) with `aphiaid BIGINT, eov VARCHAR, n_eov`.

## Examples

``` r
cat(obis_h3_species_eov_sql())
#> SELECT taxonID::BIGINT AS aphiaid, MIN(eov)::VARCHAR AS eov, COUNT(DISTINCT eov)::INTEGER AS n_eov
#> FROM eov
#> GROUP BY 1
```
