# data-raw/publish_obis_h3.sh, the host side of the monthly obis-h3 upload (OBIS_UPLOAD=host): run against a fake
# om-publish.sh (oceanmetrics/platform, the one publisher of the bucket) that records each call, and fake aws and rclone
# listings for the count check. the order (the folder, latest.json, collection.json), the prefixes, the headers, the
# history kept for the two pointers, the count check that holds the pointers back, the dry run and the tag check.

script <- normalizePath(test_path("..", "..", "data-raw", "publish_obis_h3.sh"), mustWork = FALSE)

fake_env <- function(dir, n_s3 = 3, n_r2 = 3) {
  bin <- file.path(dir, "bin"); dir.create(bin)
  writeLines(c("#!/bin/sh", "for a in \"$@\"; do printf '%s\\037' \"$a\"; done >> \"$OM_LOG\"", "echo >> \"$OM_LOG\""),
             file.path(bin, "om-publish"))
  lister <- function(var) c("#!/bin/sh", "echo \"$@\" >> \"$LIST_LOG\"", "i=0",
                            sprintf("while [ $i -lt ${%s} ]; do echo \"f$i\"; i=$((i+1)); done", var))
  writeLines(lister("N_S3"), file.path(bin, "aws"))
  writeLines(lister("N_R2"), file.path(bin, "rclone-r2.sh"))
  Sys.chmod(list.files(bin, full.names = TRUE), "0755")
  c(PATH = paste(bin, Sys.getenv("PATH"), sep = ":"), OM_PUBLISH = file.path(bin, "om-publish"),
    OM_RCLONE = file.path(bin, "rclone-r2.sh"), OM_LOG = file.path(dir, "calls"), LIST_LOG = file.path(dir, "lists"),
    N_S3 = n_s3, N_R2 = n_r2, OM_STORE = "both")
}

release <- function(dir) {
  rel <- file.path(dir, "v20261101")
  dir.create(file.path(rel, "all", "res=1"), recursive = TRUE)
  for (f in c("release.json", "files.parquet", "all/res=1/data_0.parquet")) writeLines("x", file.path(rel, f))
  writeLines("{}", file.path(dir, "latest.json")); writeLines("{}", file.path(dir, "collection.json"))
  rel
}

run_publish <- function(env, ...) {
  old <- Sys.getenv(names(env), unset = NA, names = TRUE)
  do.call(Sys.setenv, as.list(env))
  on.exit(for (k in names(old)) if (is.na(old[[k]])) Sys.unsetenv(k) else do.call(Sys.setenv, setNames(list(old[[k]]), k)))
  out <- suppressWarnings(system2("bash", c(script, ...), stdout = TRUE, stderr = TRUE))
  list(status = attr(out, "status") %||% 0L, out = out)
}

calls <- function(env) {
  if (!file.exists(env[["OM_LOG"]])) return(list())
  lapply(readLines(env[["OM_LOG"]]), function(l) strsplit(l, "\037", fixed = TRUE)[[1]])
}

test_that("the release folder goes first, then latest.json, then collection.json, through om-publish", {
  skip_if_not(file.exists(script), "data-raw/ not in this tree")
  d <- withr::local_tempdir(); env <- fake_env(d); rel <- release(d)
  r <- run_publish(env, rel, "v20261101", file.path(d, "latest.json"), file.path(d, "collection.json"))
  expect_equal(r$status, 0L, info = paste(r$out, collapse = "\n"))
  cl <- calls(env)
  expect_length(cl, 3)
  expect_equal(cl[[1]], c("--really", rel, "obis-h3/v20261101"))
  expect_equal(cl[[2]], c("--really", "--keep-history", "--cache-control", "max-age=300", file.path(d, "latest.json"),
                          "obis-h3", "--as", "latest.json"))
  expect_equal(cl[[3]][c(1:4, 6:8)], c("--really", "--keep-history", "--cache-control", "max-age=300", "obis-h3", "--as",
                                       "collection.json"))
  expect_false(any(grepl("^--delete", unlist(cl))))
  # the count check read both stores
  lists <- readLines(env[["LIST_LOG"]])
  expect_true(any(grepl("^s3 ls s3://oceanmetrics.io-public/obis-h3/v20261101/ --recursive", lists)))
  expect_true(any(grepl("^lsf -R --files-only --fast-list r2:oceanmetrics-io-public-enam/obis-h3/v20261101", lists)))
})

test_that("a store holding fewer files than the folder stops before the pointers", {
  skip_if_not(file.exists(script), "data-raw/ not in this tree")
  d <- withr::local_tempdir(); env <- fake_env(d, n_r2 = 2); rel <- release(d)
  r <- run_publish(env, rel, "v20261101", file.path(d, "latest.json"), file.path(d, "collection.json"))
  expect_equal(r$status, 1L)
  expect_true(any(grepl("R2 holds fewer files \\(2\\) than the export \\(3\\)", r$out)))
  expect_length(calls(env), 1)                       # the folder only: latest.json not written
})

test_that("the dry run passes --dry-run to every call and lists nothing", {
  skip_if_not(file.exists(script), "data-raw/ not in this tree")
  d <- withr::local_tempdir(); env <- fake_env(d); rel <- release(d)
  r <- run_publish(env, "--dry-run", rel, "v20261101", file.path(d, "latest.json"), file.path(d, "collection.json"))
  expect_equal(r$status, 0L)
  cl <- calls(env)
  expect_length(cl, 3)
  expect_true(all(vapply(cl, `[`, "", 1) == "--dry-run"))
  expect_false(file.exists(env[["LIST_LOG"]]))
})

test_that("a bad tag is a usage error and publishes nothing", {
  skip_if_not(file.exists(script), "data-raw/ not in this tree")
  d <- withr::local_tempdir(); env <- fake_env(d); rel <- release(d)
  r <- run_publish(env, rel, "2026-11-01", file.path(d, "latest.json"), file.path(d, "collection.json"))
  expect_equal(r$status, 2L)
  expect_length(calls(env), 0)
})
