# R/sample_rules.R -----------------------------------------------------
# The project's sample definition, in one place.
#
# Every exclusion decision in the project is a line in this file.
# scripts/04_build_sample.R applies it; analysis/01_eda.qmd only reports
# what it did. Nothing here scans the tracking data — the inputs are all
# measured facts from data/processed/play_index.parquet.
#
# Defines functions and constants only. No library() calls.

source(here::here("R", "coverage.R"))

# ---- flag vocabulary -------------------------------------------------

#' Human-readable label for every exclusion flag
#'
#' Named by flag so the funnel labels can't drift out of alignment with
#' the flags, which a positional vector allows.
FLAG_LABELS <- c(
  keep_live_play = "has offense_formation (not a fake/aborted snap)",
  keep_snap = "has a ball_snap event",
  keep_throw = "has a pass_forward event",
  keep_any_throw = "has a pass_forward or pass_shovel event",
  keep_arrival = "has a pass_arrived event",
  keep_los = "has a line of scrimmage",
  keep_sides = "at least 5 players tracked per side",
  keep_ball = "ball tracked for every frame",
  keep_no_dupes = "no duplicate (play, player, frame) rows",
  keep_clean_window = "no kinematic defect between snap and throw",
  keep_clean_kin = "no kinematic defect anywhere in the play",
  keep_target = "targeted receiver named and tracked",
  keep_coverage = "has a man/zone coverage label"
)

#' Whether a flag defines the population or screens for data quality
#'
#' Population filters describe the question: which plays are we asking
#' about at all. Quality filters describe the data's ability to answer it.
#' Only the second block is measurement loss, and it is only interpretable
#' as such when it runs *after* the population is defined — otherwise its
#' counts are inflated by plays that were never in scope.
FLAG_GROUP <- c(
  keep_live_play = "population",
  keep_snap = "population",
  keep_throw = "population",
  keep_any_throw = "population",
  keep_arrival = "population",
  keep_target = "population",
  keep_coverage = "population",
  keep_los = "quality",
  keep_sides = "quality",
  keep_ball = "quality",
  keep_no_dupes = "quality",
  keep_clean_window = "quality",
  keep_clean_kin = "quality"
)

stopifnot(setequal(names(FLAG_LABELS), names(FLAG_GROUP)))

# ---- the two candidate rules -----------------------------------------
# Population block first, then quality. Conjunction is order-independent,
# so the surviving count is identical under any ordering; what the
# ordering buys is that each quality step's `dropped` reads as "plays I
# wanted but cannot measure".

#' The adopted rule: kinematic exclusion scoped to the measurement window
#'
#' A play is dropped for a bad frame only when that frame falls between
#' the snap and the throw. See notes/decisions.md; the majority of
#' defective rows land after the throw.
SCOPED_FLAGS <- c(
  # population
  "keep_live_play",
  "keep_snap",
  "keep_any_throw",
  # quality
  "keep_los",
  "keep_sides",
  "keep_ball",
  "keep_no_dupes",
  "keep_clean_window"
)

#' The whole-play alternative, retained only to quantify what the scoped
#' rule costs. Not used to define the analytical sample. Differs from
#' SCOPED_FLAGS at exactly two steps: the throw anchor (3) and the
#' kinematic scope (8).
CONSERVATIVE_FLAGS <- c(
  "keep_live_play",
  "keep_snap",
  "keep_throw",
  "keep_los",
  "keep_sides",
  "keep_ball",
  "keep_no_dupes",
  "keep_clean_kin"
)

#' The project's sample definition. Changing this one line changes the
#' sample everywhere downstream.
SAMPLE_RULE <- SCOPED_FLAGS

stopifnot(length(SCOPED_FLAGS) == length(CONSERVATIVE_FLAGS))

# ---- flag construction -----------------------------------------------

#' Attach every exclusion flag to the play table
#'
#' Flags are computed for all plays whether or not the current rule uses
#' them, so a question-specific framing (coverage-conditional, targeted
#' receiver only) is a choice of flag subset rather than a rebuild.
#'
#' @param plays data/processed/plays.parquet
#' @param play_index data/processed/play_index.parquet
#' @param coverages data/processed/coverages_week1.parquet, or NULL
add_sample_flags <- function(plays, play_index, coverages = NULL) {
  df <- plays |>
    dplyr::select(
      dplyr::any_of(c(
        "game_id",
        "play_id",
        "week",
        "possession_team",
        "defense_team",
        "offense_formation",
        "personnel_o",
        "personnel_d",
        "type_dropback",
        "pass_result",
        "down",
        "quarter",
        "yards_to_go",
        "los_x",
        "play_direction"
      ))
    ) |>
    dplyr::left_join(play_index, by = c("game_id", "play_id"))

  if (is.null(coverages)) {
    df$coverage <- NA_character_
  } else {
    df <- dplyr::left_join(
      df,
      dplyr::select(coverages, game_id, play_id, coverage),
      by = c("game_id", "play_id")
    )
  }

  df |>
    dplyr::mutate(
      coverage_class = classify_coverage(coverage),

      keep_live_play = !is.na(offense_formation),
      keep_snap = !is.na(f_ball_snap),
      keep_throw = !is.na(f_pass_forward),
      keep_any_throw = !is.na(f_pass_forward) | !is.na(f_pass_shovel),
      keep_arrival = !is.na(f_pass_arrived),
      keep_los = !is.na(los_x),
      keep_sides = dplyr::coalesce(n_offense, 0L) >= 5 &
        dplyr::coalesce(n_defense, 0L) >= 5,
      keep_ball = dplyr::coalesce(ball_status == "complete", FALSE),
      keep_no_dupes = !dplyr::coalesce(has_duplicate_rows, FALSE),
      keep_clean_kin = !dplyr::coalesce(has_kinematic_defect, FALSE),
      keep_clean_window = !dplyr::coalesce(defect_in_window, FALSE),
      keep_target = !is.na(target_nfl_id) &
        dplyr::coalesce(target_tracked, FALSE),
      keep_coverage = !is.na(coverage_class)
    )
}

# ---- applying rules --------------------------------------------------

#' Logical mask for the conjunction of a set of flags
#'
#' coalesce() stops a stray NA flag from poisoning every later step.
apply_flags <- function(df, flags) {
  purrr::reduce(
    flags,
    \(acc, f) acc & dplyr::coalesce(df[[f]], FALSE),
    .init = rep(TRUE, nrow(df))
  )
}

#' Marginal failure count for every flag, independent of rule ordering
#'
#' The funnel's `dropped` is conditional on the preceding steps. These are
#' the unconditional counts: how many plays fail each criterion on its
#' own. Both are worth reporting, and conflating them is easy — the
#' missing-LOS block is larger than the number of plays the funnel
#' attributes to keep_los.
flag_marginals <- function(df, flags = names(FLAG_LABELS)) {
  tibble::tibble(
    flag = flags,
    group = unname(FLAG_GROUP[flags]),
    criterion = unname(FLAG_LABELS[flags]),
    n_failing = purrr::map_int(
      flags,
      \(f) sum(!dplyr::coalesce(df[[f]], FALSE))
    ),
    pct_failing = purrr::map_dbl(
      flags,
      \(f) mean(!dplyr::coalesce(df[[f]], FALSE))
    )
  )
}

#' Step-by-step attrition for an ordered set of flags
funnel <- function(df, flags, labels = FLAG_LABELS, groups = FLAG_GROUP) {
  stopifnot(
    all(flags %in% names(labels)),
    all(flags %in% names(groups)),
    all(flags %in% names(df))
  )

  masks <- purrr::accumulate(
    flags,
    \(acc, f) acc & dplyr::coalesce(df[[f]], FALSE),
    .init = rep(TRUE, nrow(df))
  )

  counts <- purrr::map_int(masks, sum)

  tibble::tibble(
    step_index = seq_along(counts) - 1L,
    flag = c(NA_character_, flags),
    group = c(NA_character_, unname(groups[flags])),
    step = c("all plays", unname(labels[flags])),
    dropped = c(NA_integer_, -diff(counts)),
    remaining = counts,
    pct_of_start = counts / nrow(df)
  )
}
