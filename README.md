# obisindicators
R package for generating indicators from OBIS

## Example Plots
Animated map of OBIS data limited to 1M randomly selected records per decade:
![decadal_animation](https://raw.githubusercontent.com/marinebon/obisindicators/main/static/img/decadal_animation.gif)

All data from OBIS in one map:
![all_data](https://raw.githubusercontent.com/marinebon/obisindicators/main/static/img/all_data.png)


## Install
Basic installation is simple:
```r
remotes::install_github("marinebon/obisindicators")
```

But you will also need to install dependencies.
You will need to install RTools and devtools to do this.
Once those are installed run the following to complete installation of this package and its dependencies:
```
devtools::install_local()
```

## Use

```r
library(obisindicators)
```

## Developer Stuff
### Setup

```r
devtools::install_local()
testthat::test_local()
```

When editing locally, you will need to reload the `obisindicators` from your local copy of the files. To do this use `devtools::load_all()`. Additionally, you will need to run `document()` to update things from roxygen docstrings. All of this is summarized in the cheatsheet in RStudio under `Help > Cheat Sheets > Package Dev w/ Devtools`. You must use the workflow outlined in [that pdf](https://www.rstudio.org/links/package_development_cheat_sheet) or you are gonna have a bad time. 

### Awesome-obisindicators usage from the community
project                                                                               | description
--------------------------------------------------------------------------------------|---------------------------
[global-obis-es50](https://github.com/USF-IMARS/global-obis-es50/)                    | Global biodiversity assessment.
[california-coast-ecostress-biodiversity/](https://github.com/USF-IMARS/california-coast-ecostress-biodiversity/) | Biodiversity assessment of the CA coast as relevant to NASA EcoSTRESS data.
[OHW22 Galapagos analysis](https://github.com/oceanhackweek/ohw22-proj-biodiversity-indicators) | Biodiversity assessment in the Galapagos with and without newly collected data.

### Notes on creating vignettes
* create new vignettes via `usethis::use_vignette("new_vignette_name")`
* to pre-build a vignette
    * set chunk's `eval` is false
    * then put markdown into the vignette to display the output image (or other html)
    * assets go in `vignettes` or in `man/figures` [[ref](https://github.com/r-lib/pkgdown/issues/280#issuecomment-287645977))
