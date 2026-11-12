#' Convert a single lint object to a GitLab Code Quality entry
#'
#' Transforms a lintr lint object into the structure expected by GitLab's
#' Code Quality report specification.
#'
#' @param l A lint object (list with fields: line_number, column, type,
#'   linter, message, filename).
#' @return A list matching the GitLab Code Quality JSON schema.
#' @examples
#' l <- list(
#'   line_number = 10, column = 5, type = "warning",
#'   linter = "line_length_linter", message = "Line too long",
#'   filename = "R/foo.R"
#' )
#' lint_to_codequality(l)
lint_to_codequality <- function(l) {
  line_num <- as.integer(safe_num(l$line_number, 1L))
  # col_num is included in the fingerprint (but not in GitLab's location spec)
  # for stable deduplication when the same linter fires multiple times
  # on one line.
  col_num <- as.integer(safe_num(l$column, 0L))
  lint_type <- safe_char(l$type, "style")
  linter_nm <- safe_char(l$linter, "unknown")
  msg <- safe_char(l$message, "lint finding")
  fname <- safe_char(l$filename, "unknown")

  list(
    description = msg,
    check_name = linter_nm,
    fingerprint = digest::digest(
      paste(fname, line_num, col_num, linter_nm, msg)
    ),
    severity = map_severity(lint_type),
    location = list(
      path = fname,
      lines = list(begin = line_num)
    )
  )
}
