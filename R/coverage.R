# R/coverage.R ---------------------------------------------------------
# Coverage label handling. This is a *modeling* decision, not a cleaning
# step, which is why it lives here and is applied at the sample layer
# (scripts/04_build_sample.R) rather than baked into the canonical
# tracking build. data/processed/coverages_week1.parquet carries the
# original eight-label `coverage` column verbatim, so a multi-class
# framing stays available without a rebuild.
#
# See notes/decisions.md.

#' Labels deliberately excluded from the man/zone binary
#'
#' "Prevent Zone" is a single garbage-time play. It describes game state
#' rather than scheme, so it maps to NA and drops out of any
#' coverage-conditional sample rather than inflating the zone class.
COVERAGE_EXCLUDED <- "Prevent Zone"

#' Collapse the eight coverage labels to a man/zone binary
#'
#' Precedence is explicit and matters: "Man" is tested before "Zone", so a
#' hypothetical label containing both words would classify as man. No
#' label in the 2018 week-1 vocabulary contains both, but the rule should
#' not be implicit in the order of a case_when().
classify_coverage <- function(coverage) {
  dplyr::case_when(
    coverage %in% COVERAGE_EXCLUDED ~ NA_character_,
    grepl("Man", coverage, fixed = TRUE) ~ "man",
    grepl("Zone", coverage, fixed = TRUE) ~ "zone",
    .default = NA_character_
  )
}

#' Fail if any label falls through the mapping unintentionally
#'
#' Called from scripts/02_build_canonical.R so a vocabulary change is a
#' build-time error rather than a silent drop to NA at model-fit time.
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
