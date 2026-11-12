#' Safely extract a scalar numeric field
#'
#' Guards against NULL, zero-length, and NA, all of which can occur in
#' malformed lint objects and would produce invalid JSON for GitLab.
#'
#' @param x A value to extract (typically a field from a lint object).
#' @param default Default value if x is NULL, empty, NA, or zero-length.
#' @return A single numeric/integer value.
#' @examples
#' safe_num(42)
#' safe_num(NULL)
#' safe_num(NA_integer_)
safe_num <- function(x, default = 0L) {
  if (!is.null(x) && length(x) > 0 && !is.na(x[[1]])) x[[1]] else default
}
