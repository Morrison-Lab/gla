#!/usr/bin/env Rscript
# gla: Lint + Code Quality artifact generator
#
# This script runs lintr::lint_package() and writes a GitLab Code Quality JSON
# artifact. It is invoked by templates/lint.yml after dependencies are installed.
#
# Environment variables read:
#   LINTR_ERROR_ON_LINT - "true" (default) to fail the job on lint findings
#
# Output:
#   lintr_results.json - GitLab Code Quality report (JSON array)

# Write empty artifact up front so it exists even if lint_package() errors.
# Combined with `artifacts: when: always`, this guarantees a parseable report
# is always published — even on load/lint failure.
#
# Note: If load_all() fails below, GitLab's MR widget shows "no code quality
# issues" (from the empty []) even though linting never ran. This is acceptable
# because the job itself fails (red status), making the pipeline non-passing.
# A sentinel entry was considered but would pollute the codequality report on
# every syntax-error commit.
writeLines("[]", "lintr_results.json")

# --- Helper functions from scripts/R/ ----------------------------------------
# safe_char, safe_num, map_severity and lint_to_codequality live one per file
# in gla's scripts/R/ (they were the separate glr package until glr#7).
# templates/lint.yml fetches them into GLA_R_HELPERS_DIR before running this
# script. Fail fast, before the expensive load_all() and lint_package(), when
# any of them is missing.
# ------------------------------------------------------------------------------
# The helpers go into their own environment, not the global one: the package's
# namespace sees the global environment, so a name defined there would hide
# object_usage_linter() findings for the same name in the linted code.
gla_helpers <- local({
  helpers_dir <- Sys.getenv("GLA_R_HELPERS_DIR", ".gla-R")
  helper_names <- c("safe_char", "safe_num", "map_severity", "lint_to_codequality")
  helper_files <- file.path(helpers_dir, paste0(helper_names, ".R"))
  missing_helpers <- helper_files[!file.exists(helper_files)]
  if (length(missing_helpers) > 0) {
    stop(
      "Missing gla R helper file(s): ",
      paste(missing_helpers, collapse = ", "),
      ". templates/lint.yml should fetch scripts/R/ into GLA_R_HELPERS_DIR ",
      "before running this script.",
      call. = FALSE
    )
  }
  helpers <- new.env(parent = baseenv())
  for (helper_file in helper_files) {
    sys.source(helper_file, envir = helpers)
  }
  helpers
})

# Load the package so object_usage_linter() can resolve symbols.
# If load_all() fails (e.g., syntax error in R/), the job fails here and
# the empty [] report is published. The real error is in the job log.
pkgload::load_all()

lints <- lintr::lint_package()

if (length(lints) > 0) {
  lint_json <- lapply(lints, gla_helpers$lint_to_codequality)

  jsonlite::write_json(lint_json, "lintr_results.json", auto_unbox = TRUE)
  message(sprintf("Found %d lint issue(s).", length(lints)))
  print(lints)

  if (tolower(Sys.getenv("LINTR_ERROR_ON_LINT", "true")) == "true") {
    stop("Linting failed with ", length(lints), " finding(s).", call. = FALSE)
  }
} else {
  message("No lint issues found.")
}
