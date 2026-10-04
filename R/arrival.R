# R/arrival.R ----------------------------------------------------------
# Kinematic detection of the frame at which a pass arrives.
#
# Arrival is the last frame on which the ball is still in flight, searched
# backwards from the frame of closest approach to the targeted receiver:
#
#   f_min = argmin_{f in F} d_f
#   f_arr = max{ f <= f_min : dis_f >= DIS_FLIGHT }
#
# over F = { f : f_throw < f <= f_throw + MAX_FLIGHT_FRAMES }, where d_f is
# the ball-to-receiver distance at frame f. The definition does not
# depend on the outcome. The dataset's `pass_arrived` event is not used
# because it is missing far more often on incompletions than on
# completions. See notes/decisions.md §6.
#
# Assumes standardized coordinates (standardize_direction()); `x_arr` and
# `y_arr` are returned in that frame. Requires a tracked targeted
# receiver.

source(here::here("R", "constants.R"))


#' Per-frame ball-to-receiver distance over the arrival search window
#'
#' @param ball One row per (game_id, play_id, frame_id) with `x`, `y`,
#'   `dis`. Ball rows only.
#' @param receiver One row per (game_id, play_id, frame_id) for the
#'   targeted receiver, with `x`, `y`.
#' @param throws One row per play with `f_throw`.
#' @param max_frames Search-window length in frames.
#' @return One row per (play, frame) inside the window, with `d`, `dis`,
#'   and the ball position, sorted by play and frame (detect_arrival()
#'   relies on the ordering).
build_approach <- function(
  ball,
  receiver,
  throws,
  max_frames = MAX_FLIGHT_FRAMES
) {
  receiver |>
    dplyr::rename(x_rec = x, y_rec = y) |>
    dplyr::inner_join(
      dplyr::rename(ball, x_ball = x, y_ball = y),
      by = c("game_id", "play_id", "frame_id")
    ) |>
    dplyr::inner_join(
      dplyr::select(throws, game_id, play_id, f_throw),
      by = c("game_id", "play_id")
    ) |>
    dplyr::filter(
      frame_id > f_throw,
      frame_id <= f_throw + max_frames
    ) |>
    dplyr::mutate(
      d = sqrt((x_ball - x_rec)^2 + (y_ball - y_rec)^2)
    ) |>
    dplyr::filter(!is.na(d)) |>
    dplyr::arrange(game_id, play_id, frame_id)
}


#' Index of the last in-flight frame within one play
#'
#' Finds frames at or above `dis_flight` up to the closest approach,
#' merges runs separated by at most `gap_tol` frames, and returns the end
#' of the first merged run. Bounding the search at the closest approach
#' excludes post-bounce frames.
#'
#' @param d Ball-to-receiver distance, in frame order.
#' @param dis Ball per-frame displacement, same order.
#' @param dis_flight Minimum displacement per frame that counts as flight.
#' @param gap_tol Largest gap, in frames, merged into a single run.
#' @return Integer position within `d` (not a frame number), or NA when
#'   the ball never reaches flight speed.
flight_end_index <- function(
  d,
  dis,
  dis_flight = DIS_FLIGHT,
  gap_tol = ARRIVAL_GAP_TOL
) {
  i_min <- which.min(d)
  fast <- which(dis >= dis_flight & seq_along(d) <= i_min)

  if (!length(fast)) {
    return(NA_integer_)
  }

  # A gap of g frames between fast frames gives diff == g + 1.
  brk <- which(diff(fast) > gap_tol + 1L)[1]

  if (is.na(brk)) max(fast) else fast[brk]
}


#' Reduce an approach table to one arrival row per play
#'
#' Diagnostics are returned alongside the anchor so sensitivity can be
#' checked downstream. `d_arr` and `d_min` measure whether the ball
#' reached the receiver and must not be used as model features or
#' filters.
#'
#' @param appr Output of build_approach().
#' @param dis_flight,gap_tol Passed to flight_end_index().
#' @return One row per play:
#'   f_arr           arrival frame
#'   d_arr           ball-to-receiver distance at f_arr
#'   x_arr, y_arr    ball position at f_arr
#'   f_min, d_min    frame and distance of closest approach
#'   frames_to_min   f_min - f_arr; on a completion, the catch and carry
#'   used_fallback   ball never reached flight speed; f_arr = f_min
#'   at_window_edge  closest approach is the last frame searched
#'   n_searched      frames in the window
detect_arrival <- function(
  appr,
  dis_flight = DIS_FLIGHT,
  gap_tol = ARRIVAL_GAP_TOL
) {
  appr |>
    dplyr::group_by(game_id, play_id) |>
    dplyr::summarize(
      n_searched = dplyr::n(),
      i_min = which.min(d),
      i_flight = flight_end_index(d, dis, dis_flight, gap_tol),
      i_arr = dplyr::coalesce(i_flight, i_min),
      f_arr = frame_id[i_arr],
      d_arr = d[i_arr],
      x_arr = x_ball[i_arr],
      y_arr = y_ball[i_arr],
      f_min = frame_id[i_min],
      d_min = d[i_min],
      frames_to_min = i_min - i_arr,
      used_fallback = is.na(i_flight),
      at_window_edge = i_min == n_searched,
      .groups = "drop"
    ) |>
    dplyr::select(-i_min, -i_flight, -i_arr)
}
