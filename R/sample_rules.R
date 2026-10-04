# R/sample_rules.R -----------------------------------------------------
# Sample definition: exclusion flags, the rules that combine them, and
# funnel reporting.
#
# Two layers. The base sample (FLAG_LABELS, SAMPLE_RULE) is
# question-agnostic and applied by scripts/04_build_sample.R from
# play_index.parquet and plays.parquet. The question-level population
# (QUESTION_FLAG_LABELS, QUESTION_RULE) is applied on top of it by
# scripts/08_build_model_frame.R, which also needs pbp.parquet,
# arrival.parquet, and features.parquet.

source(here::here("R", "coverage.R"))

# ---- flag vocabulary -------------------------------------------------

#' Human-readable label for every exclusion flag
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
#' Population flags define which plays are in scope; quality flags
#' identify in-scope plays that cannot be measured. Rules list population
#' flags first so that each quality step's funnel count is measurement
#' loss only.
#'
#' `keep_arrival` is a diagnostic only (group "diagnostic") and must not
#' appear in a rule: the `pass_arrived` event it tests is missing far more
#' often on incompletions (notes/decisions.md §4.8, §6.1).
FLAG_GROUP <- c(
  keep_live_play = "population",
  keep_snap = "population",
  keep_throw = "population",
  keep_any_throw = "population",
  keep_arrival = "diagnostic",
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

# ---- rules -----------------------------------------------------------

#' Adopted rule: kinematic defects count only between snap and throw
#'
#' See notes/decisions.md §4.2.
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

#' Whole-play alternative, used only to report what the scoped rule
#' changes
#'
#' Differs from SCOPED_FLAGS at steps 3 (throw anchor) and 8 (kinematic
#' scope).
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

#' The rule that defines the analytical sample
SAMPLE_RULE <- SCOPED_FLAGS

stopifnot(length(SCOPED_FLAGS) == length(CONSERVATIVE_FLAGS))

# ---- flag construction -----------------------------------------------

#' Attach every exclusion flag to the play table
#'
#' All flags are computed whether or not SAMPLE_RULE uses them.
#'
#' @param plays data/processed/plays.parquet
#' @param play_index data/processed/play_index.parquet
#' @param coverages data/processed/coverages_week1.parquet, or NULL
#' @return One row per play with the selected play columns, the play
#'   index, `coverage`, `coverage_class`, and every `keep_*` flag.
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
#' NA flags are treated as FALSE.
apply_flags <- function(df, flags) {
  purrr::reduce(
    flags,
    \(acc, f) acc & dplyr::coalesce(df[[f]], FALSE),
    .init = rep(TRUE, nrow(df))
  )
}

#' Unconditional failure count for every flag
#'
#' Unlike funnel(), whose `dropped` depends on the preceding steps.
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
#'
#' @param df A data frame carrying the flags.
#' @param flags Flag names, in order.
#' @param labels,groups Named vectors describing the flags.
#' @param outcome Optional logical vector, the length of `nrow(df)`. When
#'   given, the share of `outcome` among plays kept and dropped at each
#'   step is added, so every exclusion can be checked for selection on the
#'   outcome.
#' @return One row per step, starting with "all plays": `dropped` is
#'   conditional on every earlier step.
funnel <- function(
  df,
  flags,
  labels = FLAG_LABELS,
  groups = FLAG_GROUP,
  outcome = NULL
) {
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

  out <- tibble::tibble(
    step_index = seq_along(counts) - 1L,
    flag = c(NA_character_, flags),
    group = c(NA_character_, unname(groups[flags])),
    step = c("all plays", unname(labels[flags])),
    dropped = c(NA_integer_, -diff(counts)),
    remaining = counts,
    pct_of_start = counts / nrow(df)
  )

  if (!is.null(outcome)) {
    stopifnot(is.logical(outcome), length(outcome) == nrow(df), !anyNA(outcome))
    share <- function(m) if (any(m)) mean(outcome[m]) else NA_real_
    out$outcome_kept <- purrr::map_dbl(masks, share)
    out$outcome_dropped <- c(
      NA_real_,
      purrr::map2_dbl(masks[-length(masks)], masks[-1], \(b, k) share(b & !k))
    )
  }

  out
}


# ---- the question-level population -----------------------------------

#' Labels for the question-level flags, applied by 08_build_model_frame.R
QUESTION_FLAG_LABELS <- c(
  keep_thrown = "thrown pass (C, I, IN)",
  keep_receiver_named = "nflverse names a receiver",
  keep_not_spike = "not a QB spike",
  keep_not_scramble = "not a QB scramble",
  keep_target_tracked = "BDB targeted receiver tracked",
  keep_arrival_measured = "arrival measured",
  keep_beyond_los = "ball arrives beyond the line of scrimmage",
  keep_model_inputs = "every model input defined"
)

#' Population or quality, as for the base flags
QUESTION_FLAG_GROUP <- c(
  keep_thrown = "population",
  keep_receiver_named = "population",
  keep_not_spike = "population",
  keep_not_scramble = "population",
  keep_target_tracked = "quality",
  keep_arrival_measured = "quality",
  keep_beyond_los = "population",
  keep_model_inputs = "quality"
)

stopifnot(setequal(names(QUESTION_FLAG_LABELS), names(QUESTION_FLAG_GROUP)))

#' The question's population, in funnel order
#'
#' Population flags first, except `keep_beyond_los`: whether the ball
#' arrives beyond the line can only be evaluated once the arrival is
#' measured, so it follows the quality steps that make it measurable.
#' Spikes and scrambles are already absent from the base sample; their
#' flags are tripwires that should drop no plays. See notes/decisions.md
#' §4.9 and §7.
QUESTION_RULE <- c(
  "keep_thrown",
  "keep_receiver_named",
  "keep_not_spike",
  "keep_not_scramble",
  "keep_target_tracked",
  "keep_arrival_measured",
  "keep_beyond_los",
  "keep_model_inputs"
)

stopifnot(setequal(QUESTION_RULE, names(QUESTION_FLAG_LABELS)))

#' Attach the question-level flags, except `keep_model_inputs`
#'
#' `keep_model_inputs` depends on derived columns that
#' prepare_model_frame() adds, so 08_build_model_frame.R sets it after
#' preparing the plays that pass every earlier step.
#'
#' @param df Analytic-sample plays joined to pbp.parquet (`qb_spike`,
#'   `qb_scramble`, `receiver_player_name`) and arrival.parquet
#'   (`depth_arr`).
#' @return `df` with the `keep_*` flags in QUESTION_FLAG_LABELS other than
#'   `keep_model_inputs`; never NA.
add_question_flags <- function(df) {
  df |>
    dplyr::mutate(
      keep_thrown = dplyr::coalesce(pass_result %in% c("C", "I", "IN"), FALSE),
      keep_receiver_named = !is.na(receiver_player_name),
      keep_not_spike = !dplyr::coalesce(qb_spike == 1, FALSE),
      keep_not_scramble = !dplyr::coalesce(qb_scramble == 1, FALSE),
      keep_target_tracked = dplyr::coalesce(target_tracked, FALSE),
      keep_arrival_measured = !is.na(depth_arr),
      keep_beyond_los = dplyr::coalesce(depth_arr > 0, FALSE)
    )
}
