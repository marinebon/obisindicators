# The image the monthly obis-h3 refresh runs in (data-raw/refresh_obis_h3.sh), so the build and the
# export do not depend on whatever R and packages a host happens to have. Built and run by
# data-raw/run_refresh_docker.sh; see data-raw/README.md, "Monthly obis-h3 refresh".
#
# Pinned: R 4.6.1 (rocker), CRAN packages as Linux arm64/amd64 binaries from the Posit Package
# Manager snapshot of PPM_DATE, where duckdb is 1.5.5 (the binary lags the 1.5.6 source). The h3t
# service reads the store with duckdb 1.5.6, and a newer DuckDB opens an older one's store, never
# the other way round: keep DUCKDB_VERSION at or below h3t's. Bump PPM_DATE and the check together.
#
# The obisindicators R code is NOT copied in: the refresh sources it from the checkout mounted at
# /share/github/marinebon/obisindicators, so the image only changes when a dependency does.

FROM rocker/r-ver:4.6.1

ARG PPM_DATE=2026-09-15
ARG DUCKDB_VERSION=1.5.5

ARG AWSCLI_VERSION=2.22.0

# host tools the refresh script calls: flock, python3 (json), curl, rsync; then the AWS CLI v2
# (Ubuntu 24.04 has no awscli package), pinned, for the sync and the upload
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl python3 rsync unzip util-linux \
 && rm -rf /var/lib/apt/lists/* \
 && arch=$(uname -m) \
 && curl -fsSL -o /tmp/awscli.zip "https://awscli.amazonaws.com/awscli-exe-linux-${arch}-${AWSCLI_VERSION}.zip" \
 && unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscli.zip \
 && aws --version

# CRAN from the dated snapshot (Linux binaries where PPM has them, else source)
RUN echo "options(repos = c(CRAN = 'https://packagemanager.posit.co/cran/__linux__/noble/${PPM_DATE}'), \
  HTTPUserAgent = sprintf('R/%s R (%s)', getRversion(), paste(getRversion(), R.version\$platform, R.version\$arch, R.version\$os)))" \
  >> /usr/local/lib/R/etc/Rprofile.site \
 && Rscript -e "install.packages(c('DBI', 'duckdb', 'glue', 'jsonlite', 'httr2', 'curl', 'dplyr', 'base64enc', 'librarian'), Ncpus = 4)" \
 && Rscript -e "v <- as.character(packageVersion('duckdb')); cat('duckdb', v, '\n'); stopifnot(v == '${DUCKDB_VERSION}')"

# the DuckDB extensions the build and export load (h3 from community, spatial, httpfs), installed
# into the image so a run does not depend on the extension server; the R package keeps them in
# ~/.duckdb only when that folder exists (else a per-session temporary folder, downloaded each time)
RUN mkdir -p /root/.duckdb \
 && Rscript -e "con <- DBI::dbConnect(duckdb::duckdb()); \
  for (q in c('INSTALL h3 FROM community', 'INSTALL spatial', 'INSTALL httpfs')) DBI::dbExecute(con, q); \
  print(DBI::dbGetQuery(con, \"SELECT extension_name, extension_version FROM duckdb_extensions() WHERE installed\")); \
  DBI::dbDisconnect(con, shutdown = TRUE)"

ENV OBIS_PKG_ROOT=/share/github/marinebon/obisindicators \
    BUILD_CONTAINER=""
WORKDIR /share/github/marinebon/obisindicators
ENTRYPOINT ["data-raw/refresh_obis_h3.sh"]
