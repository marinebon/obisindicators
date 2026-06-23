library(testthat)

test_that("calc_indicators() computes ES50, richness and diversity per cell", {
  skip_if_not_installed("gsl")

  df <- data.frame(
    cell    = c("a", "a", "a", "b"),
    species = c("sp1", "sp2", "sp3", "sp1"),
    records = c(60, 30, 10, 5))

  ind <- calc_indicators(df, esn = 50)

  expect_setequal(ind$cell, c("a", "b"))
  expect_true(all(c("n", "sp", "shannon", "simpson", "es") %in% names(ind)))

  a <- ind[ind$cell == "a", ]
  expect_equal(a$n, 100)              # total records in the cell
  expect_equal(a$sp, 3)               # species richness
  expect_gt(a$es, 0)                  # ES(50) in (0, richness]
  expect_lte(a$es, 3)

  b <- ind[ind$cell == "b", ]
  expect_equal(b$n, 5)
  expect_true(is.na(b$es))            # n < esn -> ES(50) undefined
})
