#' Calculate ES50 (Hurlbert index)
#'
#' Calculate the expected number of marine species in a random sample of 50 individuals (records)
#'
#' @param df data frame
#' @param esn expected number of marine species
#'
#' @return value
#'
#' @details The expected number of marine species in a random sample of 50 individuals (records) is an indicator on marine biodiversity richness.
#' The ES50 is defined in OBIS as the `sum(esi)` over all species of the following per species calculation:
#' - when `n - ni >= 50 (with n as the total number of records in the cell and ni the total number of records for the ith-species)
#'   - `esi = 1 - exp(lngamma(n-ni+1) + lngamma(n-50+1) - lngamma(n-ni-50+1) - lngamma(n+1))`
#' - when `n >= 50`
#'   - `esi = 1`
#' - else
#'   - `esi = NULL`
#' Warning: ES50 assumes that individuals are randomly distributed, the sample size is sufficiently large, the samples are taxonomically similar, and that all of the samples have been taken in the same manner.
#'
#' @export
#' @concept analyze
#' @examples
#' @importFrom gsl lngamma
calc_es50 <- function(df, esn = 50) {
  df %>%
    group_by(cell, species) %>%
    summarize(
      ni = sum(records),
      .groups = "drop_last") %>%
    mutate(n = sum(ni)) %>%
    group_by(cell, species) %>%
    mutate(
      hi = -(ni/n*log(ni/n)),
      si = (ni/n)^2,
      qi = ni/n,
      esi = case_when(
        n-ni >= esn ~ 1-exp(gsl::lngamma(n-ni+1)+gsl::lngamma(n-esn+1)-gsl::lngamma(n-ni-esn+1)-gsl::lngamma(n+1)),
        n >= esn ~ 1
      )
    ) %>%
    group_by(cell) %>%
    summarize(
      n = sum(ni),
      sp = n(),
      shannon = sum(hi),
      simpson = sum(si),
      maxp = max(qi),
      es = sum(esi),
      .groups = "drop") %>%
    mutate(
      hill_1   = exp(shannon),
      hill_2   = 1/simpson,
      hill_inf = 1/maxp)
}
