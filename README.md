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

## Developer Stuff
### Setup
You will likely need [Rtools](https://cran.r-project.org/bin/windows/Rtools/) to install the `dggridr` dependency.
Rtools is installed separately from R and Rstudio.

```r
devtools::install_local()
testthat::test_local()
```

### Notes on creating vignettes
* create new vignettes via `usethis::use_vignette("new_vignette_name")`
* to pre-build a vignette
    * set chunk's `eval` is false
    * then put markdown into the vignette to display the output image (or other html)
    * assets go in `vignettes` or in `man/figures` [[ref](https://github.com/r-lib/pkgdown/issues/280#issuecomment-287645977))