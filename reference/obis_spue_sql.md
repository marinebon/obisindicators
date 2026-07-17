# Build an h3t tile SQL query for the SPUE effort proxy

Live per-cell
`value = records(target subtree) / records(effort subtree)`, restricted
to the effort taxon's footprint. Both subtrees are resolved with
recursive CTEs over the baked `taxon` table, so this works for arbitrary
ranks. Projects exactly `cell_id, value, n` (with `n` = effort record
count), as the `h3t` service requires. See
[`calc_spue()`](http://marinebon.org/obisindicators/reference/calc_spue.md)
for the pinned R reference.

## Usage

``` r
obis_spue_sql(
  num_aphiaid,
  den_aphiaid,
  res_max = 7L,
  res_placeholder = "{{res}}",
  bbox_placeholder = "{{bbox}}"
)
```

## Arguments

- num_aphiaid:

  target-taxon AphiaID(s) (numerator subtree).

- den_aphiaid:

  effort-taxon AphiaID(s) (denominator subtree); typically a
  higher-order taxon such as the target's parent class.

- res_max:

  cap on H3 resolution (1-7); see
  [`obis_h3t_sql()`](http://marinebon.org/obisindicators/reference/obis_h3t_sql.md).

- res_placeholder:

  resolution placeholder; default `"{{res}}"`.

- bbox_placeholder:

  spatial-prune placeholder spliced into the `occ_h3` scan; default
  `"{{bbox}}"` (the `h3t` server substitutes a per-tile `lat`/`lng`
  predicate). Pass `""` to disable for direct execution — see
  [`obis_h3t_sql()`](http://marinebon.org/obisindicators/reference/obis_h3t_sql.md).

## Value

a SQL string.
