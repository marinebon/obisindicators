# Assemble an h3t tile (or stats) URL for an OBIS indicator

Base64-encodes the SQL from
[`obis_h3t_sql()`](http://marinebon.org/obisindicators/reference/obis_h3t_sql.md)
into the `?q=` parameter.

## Usage

``` r
obis_h3t_url(
  base_url = "https://h3tcache.marinesensitivity.org/h3t/{z}/{x}/{y}.h3t",
  sql = NULL,
  release = NULL,
  db = NULL,
  ...
)
```

## Arguments

- base_url:

  tile URL template, e.g.
  `"https://h3tcache.marinesensitivity.org/h3t/{z}/{x}/{y}.h3t"`, or the
  stats endpoint `".../h3t/stats"`. For
  [`mapgl::add_h3t_source()`](https://walker-data.com/mapgl/reference/add_h3t_source.html)
  use the `h3tiles://` scheme.

- sql:

  the SQL from
  [`obis_h3t_sql()`](http://marinebon.org/obisindicators/reference/obis_h3t_sql.md)
  (or pass `...` to build it).

- release:

  optional release tag appended as `&release=`.

- db:

  optional `&db=` registry name (default server uses `obis`).

- ...:

  passed to
  [`obis_h3t_sql()`](http://marinebon.org/obisindicators/reference/obis_h3t_sql.md)
  when `sql` is missing.

## Value

the URL string with the `?q=<base64>` query embedded.
