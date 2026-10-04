# scripts/08_build_model_frame.R ---------------------------------------
# Builds the model frame: the question's population, with every model
# input, the response, and the cp benchmark, one row per play.
#
# The population rule is QUESTION_RULE in R/sample_rules.R, applied on top
# of the base analytic sample (notes/decisions.md §4.9, §7, §9.1). Each step
# is reported in the funnel with the completion rate of plays kept and
# dropped. Predictors are prepared by prepare_model_frame() in
# R/evaluate.R, so every stage and the benchmark see identical inputs.
#
# Outcome-derived columns are asserted absent: the nflverse validation
# block, plays.parquet's EPA columns, and the arrival diagnostics `d_arr`
# and `d_min`, which measure the catch itself (notes/decisions.md §6.7,
# §8.5).
#
# Also carried, for analysis/05_robustness.qmd: charted `air_yards` and
# `yards_to_go` (to rebuild distance to the sticks from charted depth), the
# p90-motion-constant timing features, and the arrival and defect
# diagnostics.
#
# Outputs, in data/processed/:
#   model_frame.parquet   one row per play in the population
#   model_funnel.parquet  step-by-step attrition with outcome shares
#
# Run after 05_join_pbp.R and 07_build_features.R.

library(arrow)
library(dplyr)
library(fs)
library(here)

source(here("R", "constants.R"))
source(here("R", "utils.R"))
source(here("R", "pbp.R"))
source(here("R", "sample_rules.R"))
source(here("R", "evaluate.R"))

processed <- here("data", "processed")
P <- function(f) read_parquet(path(processed, f))

analytic_sample <- P("analytic_sample.parquet") |>
  select(
    game_id,
    play_id,
    week,
    pass_result,
    down,
    yards_to_go,
    los_x,
    target_nfl_id,
    target_tracked,
    has_kinematic_defect
  )

plays <- P("plays.parquet") |>
  select(game_id, play_id, number_of_pass_rushers)

pbp <- P("pbp.parquet") |>
  select(
    game_id,
    play_id,
    cp,
    has_cp,
    receiver_player_name,
    air_yards,
    pass_location,
    qb_hit,
    qb_spike,
    qb_scramble,
    shotgun,
    posteam_type
  )

arrival <- P("arrival.parquet") |>
  select(game_id, play_id, depth_arr, used_fallback, at_window_edge)

features <- P("features.parquet") |>
  select(
    game_id,
    play_id,
    sep_throw,
    closing_throw,
    lev_angle,
    tta_nearest,
    window_margin,
    window_n_pos,
    tta_nearest_p90,
    window_margin_p90
  )

keys <- c("game_id", "play_id")

spine <- analytic_sample |>
  left_join(plays, by = keys) |>
  left_join(pbp, by = keys) |>
  left_join(arrival, by = keys) |>
  left_join(features, by = keys)

stopifnot(nrow(spine) == nrow(analytic_sample))

# ---- population ----------------------------------------------------------

flags <- add_question_flags(spine)

before_inputs <- QUESTION_RULE[QUESTION_RULE != "keep_model_inputs"]
passes_before <- apply_flags(flags, before_inputs)

# Lumping and clamping are computed on the population, as in the notebook
# assembly this script replaces.
prepared <- prepare_model_frame(flags[passes_before, ])

flags$keep_model_inputs <- FALSE
flags$keep_model_inputs[passes_before] <-
  stats::complete.cases(prepared[model_vars()])

stopifnot(!any(purrr::map_lgl(flags[QUESTION_RULE], anyNA)))

model_funnel <- funnel(
  flags,
  QUESTION_RULE,
  labels = QUESTION_FLAG_LABELS,
  groups = QUESTION_FLAG_GROUP,
  outcome = coalesce(flags$pass_result == "C", FALSE)
)

# Spikes and scrambles never reach the base sample's throw population, so
# these steps are tripwires.
stopifnot(all(
  model_funnel$dropped[
    model_funnel$flag %in% c("keep_not_spike", "keep_not_scramble")
  ] ==
    0
))

model_frame <- prepared[
  flags$keep_model_inputs[passes_before],
] |>
  select(
    all_of(model_vars()),
    pass_result,
    cp,
    has_cp,
    air_yards,
    yards_to_go,
    window_n_pos,
    tta_nearest_p90,
    window_margin_p90,
    used_fallback,
    at_window_edge,
    has_kinematic_defect,
    target_nfl_id
  ) |>
  relocate(game_id, play_id, week, pass_result, complete) |>
  arrange(game_id, play_id)

# ---- assertions ----------------------------------------------------------

forbidden <- c(
  "d_arr",
  "d_min",
  "f_min",
  "f_pass_arrived",
  "t_arrive",
  "t_flight",
  PBP_COLS$validate
)

assert_complete(model_frame)
assert_no_leak_cols(model_frame, allow = character(0))

stopifnot(
  !any(forbidden %in% names(model_frame)),
  !any(duplicated(model_frame[keys])),
  nrow(model_frame) == tail(model_funnel$remaining, 1),
  all(model_frame$has_cp),
  !anyNA(model_frame$cp),
  all(model_frame$depth_arr > 0)
)

write_parquet(model_frame, path(processed, "model_frame.parquet"))
write_parquet(model_funnel, path(processed, "model_funnel.parquet"))

print(as.data.frame(select(
  model_funnel,
  step,
  group,
  dropped,
  remaining,
  outcome_kept,
  outcome_dropped
)))

message(
  "Done. ",
  nrow(model_frame),
  " plays in the model frame; base rate ",
  sprintf("%.4f", mean(model_frame$complete)),
  "."
)
