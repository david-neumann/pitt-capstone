# R/coverage.R ---------------------------------------------------------
# Coverage label handling (week 1 only). The raw eight-label `coverage`
# column is kept verbatim in data/processed/coverages_week1.parquet; the
# man/zone collapse is applied at the sample layer. See
# notes/decisions.md §5.

#' Coverage labels excluded from the man/zone binary
#'
#' "Prevent Zone" describes game state rather than scheme, so it maps to
#' NA instead of zone.
COVERAGE_EXCLUDED <- "Prevent Zone"

#' Collapse coverage labels to a man/zone binary
#'
#' A label containing "Man" is classified as man before "Zone" is tested.
#'
#' @param coverage Character vector of raw labels.
#' @return Character vector of "man", "zone", or NA.
classify_coverage <- function(coverage) {
  dplyr::case_when(
    coverage %in% COVERAGE_EXCLUDED ~ NA_character_,
    grepl("Man", coverage, fixed = TRUE) ~ "man",
    grepl("Zone", coverage, fixed = TRUE) ~ "zone",
    .default = NA_character_
  )
}

#' Fail if any coverage label is not handled by classify_coverage()
#'
#' Called by scripts/02_build_canonical.R so a vocabulary change fails the
#' build instead of becoming NA downstream.
#'
#' @param coverage Character vector of raw labels.
#' @param where Name of the source table, used in the error message.
#' @return The distinct labels, invisibly.
assert_coverage_vocabulary <- function(coverage, where = "coverages_week1") {
  labels <- unique(stats::na.omit(coverage))
  unmapped <- labels[
    is.na(classify_coverage(labels)) & !labels %in% COVERAGE_EXCLUDED
  ]

  if (length(unmapped)) {
    stop(
      "Unmapped coverage labels in ",
      where,
      ": ",
      paste0(unmapped, collapse = ", "),
      ". Update classify_coverage() in R/coverage.R.",
      call. = FALSE
    )
  }

  invisible(labels)
}
