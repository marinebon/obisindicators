# Run a tile SQL at a fixed H3 resolution

Executes the read-only `SELECT cell_id, value, n` produced by
[`obis_h3t_sql()`](https://marinebon.org/obisindicators/reference/obis_h3t_sql.md),
[`obis_eov_sql()`](https://marinebon.org/obisindicators/reference/obis_eov_sql.md)
or
[`obis_spue_sql()`](https://marinebon.org/obisindicators/reference/obis_spue_sql.md)
with the `{{res}}` placeholder bound to one resolution, and returns the
cells keyed on the hex string (H3 `BIGINT` ids exceed R's double
precision, so never carry them as numbers in R).

## Usage

``` r
obis_h3t_query(con, sql, res, res_placeholder = "{{res}}")
```

## Arguments

- con:

  connection from
  [`obis_store_connect()`](https://marinebon.org/obisindicators/reference/obis_store_connect.md).

- sql:

  tile SQL containing `{{res}}` (or already resolved).

- res:

  H3 resolution to bind (1-7).

- res_placeholder:

  the placeholder string in `sql`.

## Value

data frame with `cell` (hex string), `value`, `n`.
