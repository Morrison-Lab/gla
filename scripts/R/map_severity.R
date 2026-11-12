#' Map lintr severity type to GitLab Code Quality severity
#'
#' @param lint_type A single character string (scalar): one of "error",
#'   "warning", "style", or any other string. Any other length is an
#'   error.
#' @return A GitLab Code Quality severity string: "blocker", "major",
#'   or "minor".
#' @examples
#' map_severity("error")
#' map_severity("warning")
#' map_severity("style")
#' map_severity("unknown")
map_severity <- function(lint_type) {
  stopifnot(length(lint_type) == 1L)
  severity_map <- c(error = "blocker", warning = "major", style = "minor")
  sev <- severity_map[lint_type]
  if (is.na(sev)) "minor" else unname(sev)
}
