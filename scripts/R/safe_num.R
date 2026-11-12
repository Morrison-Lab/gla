#' Safely extract a scalar numeric field
#'
#' Guards against NULL, zero-length, NA, non-numeric, and non-scalar
#' values, all of which can occur in malformed lint objects and would
#' produce invalid JSON for GitLab.
#'
#' @param x A value to extract (typically a field from a lint object).
#' @param default Default value if x is NULL, zero-length, NA, or not a
#'   numeric scalar.
#' @return A single numeric/integer value.
#' @examples
#' safe_num(42)
#' safe_num(NULL)
#' safe_num(NA_integer_)
#' safe_num("foo")
safe_num <- function(x, default = 0L) {
  usable <- !is.null(x) && length(x) > 0 &&
    is.numeric(x[[1]]) && length(x[[1]]) == 1L && !is.na(x[[1]])
  if (usable) x[[1]] else default
}
