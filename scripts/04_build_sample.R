# scripts/04_build_sample.R --------------------------------------------
# Apply the sample definition.
#
# Builds the exclusion flags, reports attrition under both candidate
# rules, and writes the plays that pass SAMPLE_RULE (R/sample_rules.R).
# Reads play-level tables only; no tracking scan.
#
# Outputs, all in data/processed/:
#   sample_flags.parquet     one row per play, every keep_* flag
#   sample_funnel.parquet    step-by-step attrition, both candidate rules
#   analytic_sample.parquet  the surviving plays
#
# Run after 03_build_play_index.R.

library(arrow)
library(dplyr)
library(tidyr)
library(purrr)
library(tibble)
library(fs)
library(here)

source(here("R", "constants.R"))
source(here("R", "utils.R"))
source(here("R", "coverage.R"))
source(here("R", "sample_rules.R"))

processed <- here("data", "processed")

plays <- read_parquet(path(processed, "plays.parquet"))
play_index <- read_parquet(path(processed, "play_index.parquet"))
coverages <- read_parquet(path(processed, "coverages_week1.parquet"))

# plays and play_index must cover the same plays; a mismatch would
# produce rows of NA flags rather than an error.
stopifnot(
  nrow(plays) == nrow(play_index),
  nrow(anti_join(
    distinct(plays, game_id, play_id),
    distinct(play_index, game_id, play_id),
    by = c("game_id", "play_id")
  )) ==
    0
)

# ---- flags -----------------------------------------------------------

sample_flags <- add_sample_flags(plays, play_index, coverages)

stopifnot(
  nrow(sample_flags) == nrow(plays),
  !any(duplicated(sample_flags[c("game_id", "play_id")])),
  # apply_flags() would treat an NA flag as FALSE.
  !any(map_lgl(sample_flags[names(FLAG_LABELS)], anyNA))
)

write_parquet(sample_flags, path(processed, "sample_flags.parquet"))

# ---- funnel ----------------------------------------------------------
# Both rules, stacked long; they differ only at steps 3 and 8.

sample_funnel <- bind_rows(
  funnel(sample_flags, SCOPED_FLAGS) |> mutate(rule = "scoped"),
  funnel(sample_flags, CONSERVATIVE_FLAGS) |> mutate(rule = "conservative")
) |>
  mutate(
    is_adopted = identical(SAMPLE_RULE, SCOPED_FLAGS) & rule == "scoped"
  ) |>
  relocate(rule, .before = step_index)

write_parquet(sample_funnel, path(processed, "sample_funnel.parquet"))

print(as.data.frame(filter(sample_funnel, rule == "scoped")))

# ---- the analytical sample -------------------------------------------
# has_kinematic_defect is kept so sensitivity to the scoped rule can be
# checked downstream: TRUE marks retained plays with a defect outside the
# snap-to-throw window. defect_in_window is FALSE for every retained play.

keep <- apply_flags(sample_flags, SAMPLE_RULE)

analytic_sample <- sample_flags |>
  filter(keep) |>
  select(
    game_id,
    play_id,
    week,
    possession_team,
    defense_team,
    play_direction,
    offense_formation,
    type_dropback,
    down,
    quarter,
    yards_to_go,
    los_x,
    pass_result,
    n_players,
    n_offense,
    n_defense,
    n_frames,
    first_frame,
    last_frame,
    f_ball_snap,
    f_pass_forward,
    f_pass_shovel,
    f_pass_arrived,
    target_nfl_id,
    target_tracked,
    coverage,
    coverage_class,
    has_kinematic_defect,
    defect_in_window
  ) |>
  mutate(
    # Throw frame accepted by keep_any_throw: pass_forward, else
    # pass_shovel.
    f_throw = coalesce(f_pass_forward, f_pass_shovel),
    throw_anchor = if_else(
      !is.na(f_pass_forward),
      "pass_forward",
      "pass_shovel"
    ),
    t_throw = (f_throw - f_ball_snap) / TRACKING_HZ,
    # t_arrive and t_flight use the pass_arrived event, which is missing
    # disproportionately on incompletions (notes/decisions.md §6.1).
    # Superseded by R/arrival.R; do not model on them.
    t_arrive = (f_pass_arrived - f_ball_snap) / TRACKING_HZ,
    t_flight = (f_pass_arrived - f_throw) / TRACKING_HZ,
    frames_pre_snap = f_ball_snap - first_frame,
    frames_post_throw = last_frame - f_throw
  ) |>
  relocate(f_throw, throw_anchor, .after = f_ball_snap)

stopifnot(
  all(!analytic_sample$defect_in_window),
  !anyNA(analytic_sample$f_throw),
  !anyNA(analytic_sample$f_ball_snap)
)

write_parquet(analytic_sample, path(processed, "analytic_sample.parquet"))

message(
  "Done. ",
  nrow(analytic_sample),
  " of ",
  nrow(sample_flags),
  " plays retained (",
  sprintf("%.1f%%", 100 * nrow(analytic_sample) / nrow(sample_flags)),
  ") across ",
  n_distinct(analytic_sample$week),
  " weeks."
)
