library(testthat)

test_that("str_length is number of characters", {
  expect_equal(stringr::str_length("a"), 1)
  expect_equal(stringr::str_length("ab"), 2)
  expect_equal(stringr::str_length("abc"), 3)
})

