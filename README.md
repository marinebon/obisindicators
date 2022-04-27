# obisindicators
R package for generating indicators from OBIS

## Install

```r
remotes::install_github("marinebon/obisindicators")
```

## Use

```r
library(obisindicators)
```

## Developer Setup
You will likely need [Rtools](https://cran.r-project.org/bin/windows/Rtools/) to install the `dggridr` dependency.
Rtools is installed separately from R and Rstudio.

```r
devtools::install_local()
testthat::test_local()
```
