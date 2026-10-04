# scripts/07_build_features.R ------------------------------------------
# Coverage features at the throw frame, one row per play, from the
# throw-frame slice built by 06_build_throw_frame.R.
#
# Stage 3 (separation):
#   sep_throw      distance from the targeted receiver to the nearest
#                  defender at the throw frame, yards
#   closing_throw  rate of change of that distance at the throw frame,
#                  yd/s; negative when the defender is closing
#
# The nearest defender is determined at the throw frame. Ties go to the
# lower nfl_id and are counted in `nearest_tied`. Missing `dir` propagates
# to NA in `closing_throw` rather than being imputed; the model frame
# decides what to do with those plays.
#
# Records measured facts only and drops no plays. No outcome columns.
#
# Output, in data/processed/:
#   features.parquet  one row per play in arrival.parquet
#
# Run after 06_build_throw_frame.R.

library(arrow)
library(dplyr)
library(fs)
library(here)

source(here("R", "constants.R"))
source(here("R", "utils.R"))
source(here("R", "geometry.R"))

processed <- here("data", "processed")

throw_frame <- read_parquet(path(processed, "throw_frame.parquet")) |>
  filter(anchor == "throw", !is_ball)
arrival <- read_parquet(path(processed, "arrival.parquet"))

target <- throw_frame |>
  filter(is_target) |>
  select(game_id, play_id, xr = x, yr = y, sr = s, dirr = dir)

defenders <- throw_frame |>
  filter(side == "defense") |>
  select(game_id, play_id, def_nfl_id = nfl_id, xd = x, yd = y, sd = s, dird = dir)

stopifnot(
  !any(duplicated(target[c("game_id", "play_id")])),
  nrow(target) == nrow(arrival)
)

# ---- stage 3: nearest defender at the throw ----------------------------

pairs <- defenders |>
  inner_join(target, by = c("game_id", "play_id")) |>
  mutate(d = sqrt((xd - xr)^2 + (yd - yr)^2))

nearest <- pairs |>
  group_by(game_id, play_id) |>
  mutate(n_defenders = n(), nearest_tied = sum(d == min(d)) > 1) |>
  arrange(d, def_nfl_id, .by_group = TRUE) |>
  slice(1) |>
  ungroup()

v_r <- velocity_xy(nearest$sr, nearest$dirr)
v_d <- velocity_xy(nearest$sd, nearest$dird)

features <- nearest |>
  mutate(
    sep_throw = d,
    closing_throw = closing_speed(
      xr,
      yr,
      v_r$vx,
      v_r$vy,
      xd,
      yd,
      v_d$vx,
      v_d$vy
    )
  ) |>
  select(
    game_id,
    play_id,
    nearest_def_nfl_id = def_nfl_id,
    n_defenders,
    nearest_tied,
    sep_throw,
    closing_throw
  )

# Every play with an arrival has a target and at least one defender.
features <- arrival |>
  select(game_id, play_id) |>
  left_join(features, by = c("game_id", "play_id")) |>
  arrange(game_id, play_id)

stopifnot(
  nrow(features) == nrow(arrival),
  !any(duplicated(features[c("game_id", "play_id")])),
  !anyNA(features$sep_throw),
  all(features$sep_throw >= 0),
  all(features$n_defenders >= 1)
)

write_parquet(features, path(processed, "features.parquet"))

message(
  "Done. ",
  nrow(features),
  " plays; ",
  sum(features$nearest_tied),
  " nearest-defender ties; ",
  sum(is.na(features$closing_throw)),
  " plays with closing_throw NA (missing dir)."
)
