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

# --- Helper functions provided by the glr package ----------------------------
# The glr package (https://gitlab.example.com/example-group/glr)
# provides safe_char, safe_num, map_severity, and lint_to_codequality.
# templates/lint.yml installs glr before running this script, so we use
# namespace-qualified calls (glr::lint_to_codequality) below.
# ------------------------------------------------------------------------------

# Early guard: fail fast with a clear message if glr wasn't installed by the
# lint template, before doing any expensive work (load_all, lint_package).
if (!requireNamespace("glr", quietly = TRUE)) {
  stop(
    "The 'glr' package is not installed. ",
    "templates/lint.yml should install it before running this script. ",
    "See: https://gitlab.example.com/example-group/glr",
    call. = FALSE
  )
}

# Load the package so object_usage_linter() can resolve symbols.
# If load_all() fails (e.g., syntax error in R/), the job fails here and
# the empty [] report is published. The real error is in the job log.
pkgload::load_all()

lints <- lintr::lint_package()

if (length(lints) > 0) {
  lint_json <- lapply(lints, glr::lint_to_codequality)

  jsonlite::write_json(lint_json, "lintr_results.json", auto_unbox = TRUE)
  message(sprintf("Found %d lint issue(s).", length(lints)))
  print(lints)

  if (tolower(Sys.getenv("LINTR_ERROR_ON_LINT", "true")) == "true") {
    stop("Linting failed with ", length(lints), " finding(s).", call. = FALSE)
  }
} else {
  message("No lint issues found.")
}
