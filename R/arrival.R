# R/arrival.R ----------------------------------------------------------
# Kinematic arrival detection. Defines functions only — no library()
# calls, no side effects.
#
# WHY THIS EXISTS. The dataset ships a `pass_arrived` event, but it is
# missing on 50.6% of incompletions against 0.8% of completions, so
# requiring it would delete half the failures of the response variable.
# The `pass_outcome_*` family covers 99.7% of plays but marks a different
# moment (the ball hitting the turf, several yards downfield of the
# receiver). Both are rejected in notes/decisions.md §6.
#
# THE DEFINITION. Arrival is the last frame on which the ball is still
# unambiguously in flight, searched backwards from the frame of closest
# approach to the targeted receiver:
#
#   f_min = argmin_{f in F} d_f
#   f_arr = max{ f <= f_min : dis_f >= DIS_FLIGHT }
#
# over F = { f : f_throw < f <= f_throw + MAX_FLIGHT_FRAMES }, with d_f
# the ball-to-targeted-receiver distance at frame f.
#
# No term in that definition depends on the outcome, which is the whole
# point: `pass_arrived` disagrees with it by about three frames on
# completions and zero on incompletions, because a caught ball keeps
# travelling into the receiver's hands while a dropped one does not.
#
# PRECONDITION: coordinates have already passed through
# standardize_direction(). Arrival is a distance and a frame number, so
# it is invariant to the rotation — but x_arr / y_arr are returned and
# those are not.
#
# REQUIRES a tracked targeted receiver. Plays without one are throwaways
# and spikes; they are removed by keep_target at the population step,
# which is a question-level decision and not this file's business.

source(here::here("R", "constants.R"))


#' Per-frame ball-to-receiver distance over the arrival search window
#'
#' The input tables are kept separate rather than pre-joined because the
#' ball table is one row per (play, frame) while the receiver table is
#' one row per (play, frame) only *after* filtering to the targeted
#' receiver. Joining them here makes that filter explicit.
#'
#' @param ball One row per (game_id, play_id, frame_id) with `x`, `y`,
#'   `dis`. Ball rows only.
#' @param receiver One row per (game_id, play_id, frame_id) for the
#'   targeted receiver, with `x`, `y`.
#' @param throws One row per play with `f_throw`.
#' @param max_frames Search-window length in frames.
#' @return One row per (play, frame) inside the window, with `d`,
#'   `dis`, and the ball position. Sorted, which detect_arrival() relies
#'   on.
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


#' Index of the last in-flight frame, within one play
#'
#' Operates on the vectors of a single play, in frame order. Returns a
#' position in those vectors, not a frame number.
#'
#' Three pieces, each earning its place:
#'
#' 1. `seq_along(d) <= i_min` bounds the search at closest approach. A
#'    hard incompletion can skip off the turf and re-exceed the flight
#'    threshold; the bound makes that unreachable. Rare (6 plays of 890
#'    show >1 yd of rise before the minimum) but the guard is free.
#'
#' 2. Runs separated by fewer than `gap_tol` frames are merged. A single
#'    frame of jitter on a wobbling ball dips below threshold mid-flight,
#'    and ending the flight there is wrong. Measured: the last-fast-frame
#'    and first-contiguous-run rules disagree on 92 of 890 week-1 plays,
#'    median gap 2 frames, max 37 — so neither extreme is right.
#'
#' 3. The END of the first merged run, not the start. The start is the
#'    release; the end is the arrival.
#'
#' @param d Ball-to-receiver distance, in frame order.
#' @param dis Ball per-frame displacement, same order.
#' @return Integer position, or NA when the ball never reaches flight
#'   speed inside the window (batted balls, soft flips).
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

  # diff(fast) == 1 is contiguous; a gap of g missing frames gives
  # diff == g + 1. Break where the gap exceeds the tolerance.
  brk <- which(diff(fast) > gap_tol + 1L)[1]

  if (is.na(brk)) max(fast) else fast[brk]
}


#' Reduce an approach table to one arrival row per play
#'
#' Diagnostics travel with the result rather than being filtered on, the
#' same pattern as has_kinematic_defect / defect_in_window in the sample
#' layer: a downstream model can test sensitivity without rebuilding.
#'
#' d_arr AND d_min ARE NOT MODEL FEATURES. A ball ending up 0.12 yd from
#' the receiver is the catch. Including either would drive log loss down
#' while saying nothing about whether coverage geometry carries
#' information. They are validation quantities and Methods numbers.
#'
#' @param appr Output of build_approach().
#' @return One row per play:
#'   f_arr           arrival frame — the anchor
#'   d_arr           ball-to-receiver distance at f_arr
#'   x_arr, y_arr    ball position at f_arr — the lane endpoint
#'   f_min, d_min    closest approach; face-validity diagnostic
#'   frames_to_min   f_min - f_arr. On a completion this is the catch
#'                   plus the carry, not a gather time.
#'   used_fallback   TRUE where the ball never reached flight speed and
#'                   closest approach was used instead
#'   at_window_edge  closest approach sat at the window boundary
#'   n_searched      frames available in the window
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
