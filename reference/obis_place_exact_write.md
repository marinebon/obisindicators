# Write the exact place indicators as Parquet

Writes the result of
[`obis_place_indicators_exact()`](https://marinebon.org/obisindicators/reference/obis_place_indicators_exact.md)
as the public derived tables of the `obis-h3` release: values only, no
geometry.

## Usage

``` r
obis_place_exact_write(result, dir, coll)
```

## Arguments

- result:

  the list returned by
  [`obis_place_indicators_exact()`](https://marinebon.org/obisindicators/reference/obis_place_indicators_exact.md).

- dir:

  output directory (a release directory); files go under
  `dir/place_exact/coll=<coll>/`.

- coll:

  the collection slug (letters, digits, `.`, `_`, `-`).

## Value

invisibly, the paths of the three files written.

## Details

    <dir>/place_exact/coll=<coll>/indicators.parquet   place_id, eov, decade, n, sp, shannon,
                                                       simpson, es, hill_1, hill_2, bp, density
    <dir>/place_exact/coll=<coll>/years.parquet        place_id, eov, year, n, sp, shannon,
                                                       simpson, es, hill_1, hill_2, bp, density
    <dir>/place_exact/coll=<coll>/meta.json            coll, places, rows, records_in/out/total,
                                                       overlaps, created, obisindicators_version

The Parquet files are ZSTD compressed (DuckDB `COPY`), ordered by place.
