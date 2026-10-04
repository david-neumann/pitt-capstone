# scripts/06_build_throw_frame.R ---------------------------------------
# Applies the arrival definition in R/arrival.R to the full season and
# extracts the tracking rows at the throw and arrival frames.
#
# Records measured facts only and drops no plays from the sample. Arrival
# requires a tracked targeted receiver, so the outputs cover the plays in
# analytic_sample.parquet with `target_tracked`. No outcome columns are
# written; join `pass_result` from analytic_sample.parquet when needed.
#
# Outputs, all in data/processed/:
#   arrival.parquet      one row per play: arrival frame and point, flight
#                        time, lane length, depth, and diagnostics
#   approach.parquet     one row per (play, frame) in the search window:
#                        ball-to-receiver distance, ball displacement, and
#                        ball position; detect_arrival() can be re-run on it
#   throw_frame.parquet  one row per (play, anchor, tracked object) at
#                        anchor "throw" (f_throw) and "arrival" (f_arr)
#
# `d_arr` and `d_min` are diagnostics, never model features or filters
# (notes/decisions.md §6.7).
#
# Run after 04_build_sample.R. Reads tracking one week at a time.

library(arrow)
library(dplyr)
library(purrr)
library(fs)
library(here)

source(here("R", "constants.R"))
source(here("R", "utils.R"))
source(here("R", "arrival.R"))

processed <- here("data", "processed")

trk <- open_dataset(path(processed, "tracking"))
analytic_sample <- read_parquet(path(processed, "analytic_sample.parquet"))

targets <- analytic_sample |>
  filter(target_tracked) |>
  select(game_id, play_id, week, f_throw, target_nfl_id, los_x)

stopifnot(
  !anyNA(targets$f_throw),
  !anyNA(targets$target_nfl_id),
  !anyNA(targets$los_x),
  !any(duplicated(targets[c("game_id", "play_id")]))
)

# Columns carried into the throw-frame slice.
SLICE_COLS <- c(
  "game_id",
  "play_id",
  "frame_id",
  "nfl_id",
  "display_name",
  "position",
  "jersey_number",
  "team_abbr",
  "side",
  "is_ball",
  "x",
  "y",
  "s",
  "a",
  "dis",
  "o",
  "dir"
)

# ---- arrival, one week at a time --------------------------------------

build_week <- function(w) {
  message("Week ", w)
  tw <- filter(targets, week == w)

  rows <- trk |>
    filter(week == w) |>
    select(all_of(SLICE_COLS)) |>
    collect() |>
    cast_keys() |>
    semi_join(tw, by = c("game_id", "play_id"))

  ball <- rows |>
    filter(is_ball) |>
    select(game_id, play_id, frame_id, x, y, dis)

  receiver <- rows |>
    filter(!is_ball) |>
    inner_join(
      select(tw, game_id, play_id, target_nfl_id),
      by = c("game_id", "play_id", "nfl_id" = "target_nfl_id")
    ) |>
    select(game_id, play_id, frame_id, x, y)

  appr <- build_approach(ball, receiver, tw)
  arr <- detect_arrival(appr)

  # Ball position at the throw: the lane origin.
  origin <- ball |>
    inner_join(
      select(tw, game_id, play_id, f_throw),
      by = c("game_id", "play_id", "frame_id" = "f_throw")
    ) |>
    select(game_id, play_id, x_throw = x, y_throw = y)

  arr <- arr |>
    inner_join(tw, by = c("game_id", "play_id")) |>
    left_join(origin, by = c("game_id", "play_id")) |>
    mutate(
      t_flight = (f_arr - f_throw) / TRACKING_HZ,
      lane_len = sqrt((x_arr - x_throw)^2 + (y_arr - y_throw)^2),
      depth_arr = x_arr - los_x
    )

  anchors <- bind_rows(
    transmute(arr, game_id, play_id, frame_id = f_throw, anchor = "throw"),
    transmute(arr, game_id, play_id, frame_id = f_arr, anchor = "arrival")
  )

  slice <- rows |>
    inner_join(anchors, by = c("game_id", "play_id", "frame_id")) |>
    left_join(
      select(tw, game_id, play_id, target_nfl_id),
      by = c("game_id", "play_id")
    ) |>
    mutate(is_target = !is_ball & nfl_id == target_nfl_id) |>
    select(-target_nfl_id) |>
    relocate(anchor, .after = frame_id)

  list(
    arrival = arr,
    approach = select(appr, game_id, play_id, frame_id, d, dis, x_ball, y_ball),
    slice = slice
  )
}

weeks <- map(sort(unique(targets$week)), build_week)

arrival <- list_rbind(map(weeks, "arrival")) |>
  select(
    game_id,
    play_id,
    week,
    target_nfl_id,
    f_throw,
    f_arr,
    t_flight,
    x_throw,
    y_throw,
    x_arr,
    y_arr,
    lane_len,
    los_x,
    depth_arr,
    d_arr,
    f_min,
    d_min,
    frames_to_min,
    used_fallback,
    at_window_edge,
    n_searched
  ) |>
  arrange(game_id, play_id)

approach <- list_rbind(map(weeks, "approach")) |>
  arrange(game_id, play_id, frame_id)

throw_frame <- list_rbind(map(weeks, "slice")) |>
  arrange(game_id, play_id, anchor, is_ball, nfl_id)

# ---- assertions ----------------------------------------------------------

n_missing <- nrow(anti_join(targets, arrival, by = c("game_id", "play_id")))

stopifnot(
  !any(duplicated(arrival[c("game_id", "play_id")])),
  all(arrival$f_arr > arrival$f_throw),
  all(arrival$f_arr <= arrival$f_throw + MAX_FLIGHT_FRAMES),
  !anyNA(arrival$x_throw),
  # Each play has exactly one ball row and one target row at each anchor.
  throw_frame |>
    filter(is_ball | is_target) |>
    count(game_id, play_id, anchor, is_ball) |>
    pull(n) |>
    (\(n) all(n == 1))(),
  n_distinct(throw_frame$game_id, throw_frame$play_id) == nrow(arrival)
)

write_parquet(arrival, path(processed, "arrival.parquet"))
write_parquet(approach, path(processed, "approach.parquet"))
write_parquet(throw_frame, path(processed, "throw_frame.parquet"))

message(
  "Done. ",
  nrow(arrival),
  " of ",
  nrow(targets),
  " plays with a tracked target have an arrival (",
  n_missing,
  " without an approach series); ",
  sum(arrival$used_fallback),
  " used the closest-approach fallback; ",
  nrow(throw_frame),
  " throw-frame rows."
)
