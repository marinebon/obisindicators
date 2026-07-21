# Sightings-per-unit-effort (SPUE) effort proxy, per H3 cell (R reference)

Presence-only effort proxy: within the spatial footprint of a
higher-order "effort" taxon (e.g. all Cetacea, from multi-species
surveys), the fraction of records that are the target taxon.
`spue = n_num / n_den` where the denominator is every record of the
effort subtree in the cell and the numerator is the subset that are the
target subtree. This is the pure-R reference pinned to
[`obis_spue_sql()`](https://marinebon.org/obisindicators/reference/obis_spue_sql.md)
by the package tests.

## Usage

``` r
calc_spue(df, num_aphiaid, den_aphiaid)
```

## Arguments

- df:

  data frame of species-level records with columns `cell`, `aphiaid`,
  `records` (as in `occ_h3`).

- num_aphiaid:

  integer AphiaIDs of the **target** subtree (already resolved via
  [`obis_taxon_children()`](https://marinebon.org/obisindicators/reference/obis_taxon_children.md)).

- den_aphiaid:

  integer AphiaIDs of the **effort** subtree (denominator).

## Value

data frame with `cell`, `n_num`, `n_den`, `spue`; only cells with effort
records (`n_den > 0`) are returned.
