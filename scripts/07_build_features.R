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
# Stage 4 (geometry), on the lane from the ball at the throw to the arrival
# point (arrival.parquet):
#   lev_angle      direction of the nearest defender from the receiver in
#                  lane coordinates, radians: 0 over the top, +-pi
#                  underneath, +pi/2 inside, -pi/2 outside. A direction
#                  only, because sep_throw is its magnitude and l_par,
#                  l_perp, and sep together are redundant.
#   tta_nearest    ball flight time minus the nearest defender's time to
#                  the arrival point, seconds; positive when the defender
#                  can get there first
#   window_margin  over defenders other than the nearest, the largest
#                  max_u [u T - tau_j(u)]: how far ahead of the ball the
#                  best-placed help defender can reach any point u of the
#                  lane, seconds (notes/decisions.md §7)
#   window_n_pos   number of those defenders with a positive margin;
#                  descriptive only
#   tta_nearest_p90, window_margin_p90
#                  the same, with the p90 motion constants
#                  (PLAYER_S_MAX_P90, PLAYER_A_MAX_P90), for the
#                  robustness refit
#
# The nearest defender is determined at the throw frame. Ties go to the
# lower nfl_id and are counted in `nearest_tied`. Missing `dir` propagates
# to NA rather than being imputed, as does `lev_angle` on the few plays
# where the ball did not move between the throw and arrival frames (no
# lane); the model frame decides what to do with those plays.
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

# Lane positions at which each help defender is timed against the ball,
# which is assumed to travel the lane at constant speed.
WINDOW_U <- seq(0, 1, by = 0.05)

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

# ---- stage 4: leverage, time to arrival, passing window -----------------

lane <- arrival |>
  select(game_id, play_id, x_throw, y_throw, x_arr, y_arr, t_flight)

nearest_geo <- nearest |>
  select(game_id, play_id, def_nfl_id, xr, yr, xd, yd, sd, dird) |>
  inner_join(lane, by = c("game_id", "play_id"))

# Time-based features for given motion constants. `nearest_geo` has one row
# per play (nearest defender and lane); `help` one row per other defender
# with velocity components.
time_features <- function(nearest_geo, help, v_max, a_max) {
  v_n <- velocity_xy(nearest_geo$sd, nearest_geo$dird)

  tta <- nearest_geo |>
    transmute(
      game_id,
      play_id,
      tta_nearest = t_flight -
        time_to_point(xd, yd, v_n$vx, v_n$vy, x_arr, y_arr, v_max, a_max)
    )

  window <- tidyr::crossing(help, u = WINDOW_U) |>
    mutate(
      px = x_throw + u * (x_arr - x_throw),
      py = y_throw + u * (y_arr - y_throw),
      margin = u * t_flight -
        time_to_point(xd, yd, vxd, vyd, px, py, v_max, a_max)
    ) |>
    group_by(game_id, play_id, def_nfl_id) |>
    # NA when the defender's direction is missing, so it is not silently
    # ignored in the play-level maximum below.
    summarize(margin = max(margin), .groups = "drop") |>
    group_by(game_id, play_id) |>
    summarize(
      window_margin = max(margin),
      window_n_pos = sum(margin > 0),
      .groups = "drop"
    )

  full_join(tta, window, by = c("game_id", "play_id"))
}

lev <- rotate_to_lane(
  nearest_geo$x_throw,
  nearest_geo$y_throw,
  nearest_geo$x_arr,
  nearest_geo$y_arr,
  nearest_geo$xd,
  nearest_geo$yd,
  nearest_geo$xr,
  nearest_geo$yr
)
leverage <- nearest_geo |>
  mutate(
    l_par = lev$l_par,
    l_io = to_inside_outside(lev$l_perp, yr),
    lev_angle = atan2(l_io, l_par)
  ) |>
  select(game_id, play_id, l_par, l_io, lev_angle)

# Help defenders: every defender except the nearest, timed to each lane
# position.
help <- defenders |>
  anti_join(
    select(nearest, game_id, play_id, def_nfl_id),
    by = c("game_id", "play_id", "def_nfl_id")
  ) |>
  inner_join(lane, by = c("game_id", "play_id"))

v_h <- velocity_xy(help$sd, help$dird)
help <- mutate(help, vxd = v_h$vx, vyd = v_h$vy)

timing <- time_features(nearest_geo, help, PLAYER_S_MAX, PLAYER_A_MAX)
timing_p90 <- time_features(
  nearest_geo,
  help,
  PLAYER_S_MAX_P90,
  PLAYER_A_MAX_P90
) |>
  select(
    game_id,
    play_id,
    tta_nearest_p90 = tta_nearest,
    window_margin_p90 = window_margin
  )

features <- features |>
  left_join(leverage, by = c("game_id", "play_id")) |>
  left_join(timing, by = c("game_id", "play_id")) |>
  left_join(timing_p90, by = c("game_id", "play_id"))

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
  all(features$n_defenders >= 2),
  # Leverage is undefined only where the ball did not move between the
  # throw and arrival frames.
  identical(
    is.na(features$lev_angle),
    arrival$lane_len[match(
      paste(features$game_id, features$play_id),
      paste(arrival$game_id, arrival$play_id)
    )] == 0
  ),
  all(abs(features$lev_angle) <= pi, na.rm = TRUE),
  # The direction and magnitude reproduce the lane offsets.
  with(
    filter(features, !is.na(l_par)),
    isTRUE(all.equal(l_par^2 + l_io^2, sep_throw^2))
  )
)

write_parquet(features, path(processed, "features.parquet"))

message(
  "Done. ",
  nrow(features),
  " plays; ",
  sum(features$nearest_tied),
  " nearest-defender ties; ",
  sum(is.na(features$closing_throw)),
  " with closing_throw NA, ",
  sum(is.na(features$tta_nearest)),
  " with tta_nearest NA, ",
  sum(is.na(features$window_margin)),
  " with window_margin NA (missing dir); ",
  sum(is.na(features$lev_angle)),
  " with lev_angle NA (zero-length lane)."
)
