# Tests for the lint helpers in scripts/R/, ported from the glr package's
# testthat suite (glr#7). glr's snapshot files are written out here as
# explicit expectations, since its snapshot helper (snapr) is not on CRAN.
#
# Run from the repository root:
#   Rscript -e 'testthat::test_file("tests/R/test-codequality.R")'

# test_file() runs with tests/R/ as the working directory.
helper_dir <- file.path("..", "..", "scripts", "R")
helper_files <- list.files(helper_dir, pattern = "[.]R$", full.names = TRUE)
if (length(helper_files) == 0) {
  stop("No helper files found in ", normalizePath(helper_dir, mustWork = FALSE))
}
for (helper_file in helper_files) {
  source(helper_file, local = TRUE)
}

mock_lint <- list(
  filename = "R/foo.R",
  line_number = 10,
  column = 5,
  type = "warning",
  linter = "line_length_linter",
  message = "Lines should not be more than 80 characters."
)

fallback_entry <- list(
  description = "lint finding",
  check_name = "unknown",
  fingerprint = "2cc2ab6cfbb5c0c37fb9dd2b59be8151",
  severity = "minor",
  location = list(path = "unknown", lines = list(begin = 1L))
)

testthat::test_that("map_severity() maps known types", {
  testthat::expect_identical(map_severity("error"), "blocker")
  testthat::expect_identical(map_severity("warning"), "major")
  testthat::expect_identical(map_severity("style"), "minor")
})

testthat::test_that("map_severity() maps unknown types to 'minor'", {
  for (type in c("info", "convention", "unknown", "")) {
    testthat::expect_identical(map_severity(type), "minor")
  }
})

testthat::test_that("map_severity() errors on non-scalar input", {
  testthat::expect_error(map_severity(c("error", "warning")))
  testthat::expect_error(map_severity(character(0)))
})

testthat::test_that("lint_to_codequality() converts a typical lint", {
  testthat::expect_identical(
    lint_to_codequality(mock_lint),
    list(
      description = "Lines should not be more than 80 characters.",
      check_name = "line_length_linter",
      fingerprint = "f6bcba33d3f38510583845f11c472c27",
      severity = "major",
      location = list(path = "R/foo.R", lines = list(begin = 10L))
    )
  )
})

testthat::test_that("lint_to_codequality() fingerprints are stable and distinct", {
  first <- lint_to_codequality(mock_lint)
  testthat::expect_identical(first$fingerprint, lint_to_codequality(mock_lint)$fingerprint)
  testthat::expect_match(first$fingerprint, "^[0-9a-f]{32}$")
  moved <- utils::modifyList(mock_lint, list(line_number = 20))
  testthat::expect_false(first$fingerprint == lint_to_codequality(moved)$fingerprint)
})

testthat::test_that("lint_to_codequality() falls back on all-NULL fields", {
  null_lint <- list(
    filename = NULL, line_number = NULL, column = NULL,
    type = NULL, linter = NULL, message = NULL
  )
  testthat::expect_identical(lint_to_codequality(null_lint), fallback_entry)
})

testthat::test_that("lint_to_codequality() falls back on all-NA fields", {
  na_lint <- list(
    filename = NA_character_, line_number = NA_integer_,
    column = NA_integer_, type = NA_character_,
    linter = NA_character_, message = NA_character_
  )
  testthat::expect_identical(lint_to_codequality(na_lint), fallback_entry)
})

testthat::test_that("lint_to_codequality() maps severity across types", {
  as_error <- utils::modifyList(mock_lint, list(type = "error"))
  as_style <- utils::modifyList(mock_lint, list(type = "style"))
  testthat::expect_identical(lint_to_codequality(as_error)$severity, "blocker")
  testthat::expect_identical(lint_to_codequality(as_style)$severity, "minor")
})

testthat::test_that("the JSON matches GitLab's Code Quality format", {
  entry <- lint_to_codequality(list(
    filename = "R/bar.R", line_number = 42, column = 1,
    type = "error", linter = "assignment_linter",
    message = "Use <-, not =, for assignment."
  ))
  json <- jsonlite::toJSON(list(entry), auto_unbox = TRUE)
  testthat::expect_identical(
    as.character(json),
    paste0(
      '[{"description":"Use <-, not =, for assignment.",',
      '"check_name":"assignment_linter",',
      '"fingerprint":"9686f2198fb4ab327142eb031a6cc1b5",',
      '"severity":"blocker",',
      '"location":{"path":"R/bar.R","lines":{"begin":42}}}]'
    )
  )
})

testthat::test_that("no lints give an empty JSON array", {
  json <- jsonlite::toJSON(lapply(list(), lint_to_codequality), auto_unbox = TRUE)
  testthat::expect_identical(as.character(json), "[]")
})

testthat::test_that("safe_char() returns the first value if it is non-empty", {
  testthat::expect_identical(safe_char("hello"), "hello")
  testthat::expect_identical(safe_char(c("first", "second")), "first")
})

testthat::test_that("safe_char() returns the default for NULL, empty, and NA", {
  for (value in list(NULL, character(0), "", NA_character_)) {
    testthat::expect_identical(safe_char(value), "")
    testthat::expect_identical(safe_char(value, "fallback"), "fallback")
  }
})

testthat::test_that("safe_num() returns the first value", {
  testthat::expect_identical(safe_num(42), 42)
  testthat::expect_identical(safe_num(3.14), 3.14)
  testthat::expect_identical(safe_num(c(10, 20, 30)), 10)
  testthat::expect_identical(safe_num(7L), 7L)
})

testthat::test_that("safe_num() returns the default for a non-numeric value", {
  testthat::expect_identical(safe_num("foo"), 0L)
  testthat::expect_identical(safe_num("12", 1L), 1L)
  testthat::expect_identical(safe_num(list("foo"), 3L), 3L)
})

testthat::test_that("safe_num() returns the default for a non-scalar element", {
  testthat::expect_identical(safe_num(list(numeric(0)), 4L), 4L)
  testthat::expect_identical(safe_num(list(c(1, 2)), 5L), 5L)
})

testthat::test_that("safe_num() returns the default for NULL, empty, and NA", {
  testthat::expect_identical(safe_num(NULL), 0L)
  testthat::expect_identical(safe_num(NULL, 99L), 99L)
  testthat::expect_identical(safe_num(numeric(0)), 0L)
  testthat::expect_identical(safe_num(integer(0), 5L), 5L)
  testthat::expect_identical(safe_num(NA), 0L)
  testthat::expect_identical(safe_num(NA_integer_, 1L), 1L)
  testthat::expect_identical(safe_num(NA_real_, 2L), 2L)
})
