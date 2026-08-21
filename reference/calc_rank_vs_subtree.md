# Records and species by DwC rank column vs by AphiaID subtree

For each preset, counts records and species at the base resolution two
ways: filtering the Darwin Core rank column (`"<rank>" = '<name>'`) and
filtering `aphiaid` by the recursive WoRMS subtree of the seed id. Where
WoRMS files the name at a rank other than the column (e.g.
Actinopterygii is a gigaclass; OBIS's `class` carries Teleostei), the
rank column silently returns zero while the subtree finds the records.

## Usage

``` r
calc_rank_vs_subtree(con, presets = obis_rank_presets(), res = H3T_RES_BASE)
```

## Arguments

- con:

  connection from
  [`obis_store_connect()`](https://marinebon.org/obisindicators/reference/obis_store_connect.md).

- presets:

  data frame with `label`, `rank`, `name`, `aphiaid`; default
  [`obis_rank_presets()`](https://marinebon.org/obisindicators/reference/obis_rank_presets.md).

- res:

  resolution tier of `occ_h3` to count on (default the base, 7).

## Value

data frame with `label`, `rank`, `name`, `aphiaid`, `records_rank`,
`species_rank`, `records_tree`, `species_tree`, `ratio`
(`records_rank / records_tree`).
