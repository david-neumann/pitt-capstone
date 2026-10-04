# R/geometry.R ---------------------------------------------------------
# Vectorized geometry for coverage features.
#
# Conventions:
#
# - Coordinates are standardized (standardize_direction()): the offense
#   advances toward +x. x runs 0..FIELD_LENGTH with goal lines at 10 and
#   110; y runs 0..FIELD_WIDTH. Unstandardized input gives mirrored
#   signs without any error.
# - `dir` and `o` are degrees clockwise from +y (dir = 90 is +x), not the
#   mathematical convention, so vx = s sin(dir) and vy = s cos(dir).
#   Verified in analysis/01_eda.qmd §2.6.
# - Units are yards, seconds, yd/s, and yd/s^2.
# - NA inputs propagate to NA outputs; nothing is dropped or imputed.
# - Every function is elementwise over equal-length vectors, for use
#   inside mutate() on large pairwise tables.
# - Division is guarded by dividing by a copy of the denominator with NA
#   in place of zero (`d_safe`), because if_else() evaluates both
#   branches.

source(here::here("R", "constants.R"))

# ---- velocity --------------------------------------------------------

#' Velocity components from speed and direction
#'
#'   vx = s * sin(dir * pi / 180)
#'   vy = s * cos(dir * pi / 180)
#'
#' @param s Speed in yd/s.
#' @param dir Direction of motion, degrees clockwise from +y.
#' @return A list with numeric vectors `vx` and `vy`.
velocity_xy <- function(s, dir) {
  rad <- dir * pi / 180
  list(vx = s * sin(rad), vy = s * cos(rad))
}


#' Bearing from one point to another
#'
#' In the tracking convention (degrees clockwise from +y), so directly
#' comparable to `dir` and `o`.
#'
#' @param x,y Origin.
#' @param tx,ty Target.
#' @return Degrees in [0, 360); NA where the points coincide.
bearing_to <- function(x, y, tx, ty) {
  dx <- tx - x
  dy <- ty - y
  deg <- atan2(dx, dy) * 180 / pi
  dplyr::if_else(dx == 0 & dy == 0, NA_real_, deg %% 360)
}


#' Signed smallest angle from bearing `a` to bearing `b`
#'
#' @param a,b Bearings in degrees.
#' @return Degrees in [-180, 180).
angle_diff_deg <- function(a, b) {
  ((b - a + 180) %% 360) - 180
}


# ---- separation ------------------------------------------------------

#' Rate of change of the distance between two players
#'
#' The relative velocity projected onto the unit separation vector:
#'
#'   d_dot = ((v_d - v_r) . (x_d - x_r)) / ||x_d - x_r||
#'
#' Computed from instantaneous velocity, so it is defined at a single
#' frame. Motion perpendicular to the separation vector contributes
#' nothing, so this is not a measure of defender speed.
#'
#' @param xr,yr Receiver position.
#' @param vxr,vyr Receiver velocity components.
#' @param xd,yd Defender position.
#' @param vxd,vyd Defender velocity components.
#' @return yd/s; negative when the gap is closing. NA where the players
#'   coincide.
closing_speed <- function(xr, yr, vxr, vyr, xd, yd, vxd, vyd) {
  dx <- xd - xr
  dy <- yd - yr
  d <- sqrt(dx^2 + dy^2)
  d_safe <- dplyr::if_else(d == 0, NA_real_, d)

  ((vxd - vxr) * dx + (vyd - vyr) * dy) / d_safe
}


# ---- leverage --------------------------------------------------------

#' Defender offset from the receiver in throwing-lane coordinates
#'
#' With u the unit vector from the lane origin (x0, y0) to the endpoint
#' (x1, y1) and delta = x_d - x_r:
#'
#'   l_par  = delta . u
#'   l_perp = u_x * delta_y - u_y * delta_x
#'
#' `l_par < 0`: defender between the passer and receiver.
#' `l_par > 0`: defender beyond the receiver.
#' `l_perp > 0`: defender to the left of the lane direction.
#' Use to_inside_outside() to convert `l_perp` to inside/outside.
#'
#' `l_par^2 + l_perp^2` equals the squared receiver-defender distance, so
#' the pair and that distance carry the same information and should not
#' enter a model together.
#'
#' @param x0,y0 Lane origin (ball at the throw).
#' @param x1,y1 Lane endpoint (arrival point, or receiver position).
#' @param xd,yd Defender position.
#' @param xr,yr Receiver position.
#' @return A list with numeric vectors `l_par` and `l_perp`; NA where the
#'   lane has zero length.
rotate_to_lane <- function(x0, y0, x1, y1, xd, yd, xr, yr) {
  lx <- x1 - x0
  ly <- y1 - y0
  len <- sqrt(lx^2 + ly^2)
  len_safe <- dplyr::if_else(len == 0, NA_real_, len)

  ux <- lx / len_safe
  uy <- ly / len_safe

  delta_x <- xd - xr
  delta_y <- yd - yr

  list(
    l_par = delta_x * ux + delta_y * uy,
    l_perp = ux * delta_y - uy * delta_x
  )
}


#' Convert a left/right lane offset to inside/outside
#'
#' Inside is toward the middle of the field. Exact for a lane pointing
#' straight downfield and approximate otherwise.
#'
#' @param l_perp Signed lateral offset from rotate_to_lane().
#' @param yr Receiver y.
#' @param midline Field centre in y.
#' @return Positive when the defender is inside the receiver, negative
#'   when outside.
to_inside_outside <- function(l_perp, yr, midline = FIELD_WIDTH / 2) {
  dplyr::if_else(yr <= midline, l_perp, -l_perp)
}


# ---- passing window --------------------------------------------------

#' Distance from a point to a line segment
#'
#' The projection parameter is clamped to [0, 1], so points beyond either
#' end are measured to the nearer endpoint rather than to the infinite
#' line. A zero-length segment measures distance to the origin.
#'
#' @param x0,y0 Segment start (ball at the throw).
#' @param x1,y1 Segment end (arrival point).
#' @param px,py Point to measure (defender position).
#' @return A list with numeric vectors:
#'   perp_dist  distance to the segment, in yards
#'   t_along    projection parameter clamped to [0, 1]
#'   t_raw      unclamped; < 0 behind the origin, > 1 past the endpoint,
#'              NA for a zero-length segment
point_to_segment <- function(x0, y0, x1, y1, px, py) {
  lx <- x1 - x0
  ly <- y1 - y0
  len2 <- lx^2 + ly^2
  len2_safe <- dplyr::if_else(len2 == 0, NA_real_, len2)

  t_raw <- ((px - x0) * lx + (py - y0) * ly) / len2_safe
  t <- dplyr::coalesce(pmin(pmax(t_raw, 0), 1), 0)

  cx <- x0 + t * lx
  cy <- y0 + t * ly

  list(
    perp_dist = sqrt((px - cx)^2 + (py - cy)^2),
    t_along = t,
    t_raw = t_raw
  )
}


# ---- time to arrival -------------------------------------------------

#' Time for a player to reach a point
#'
#' The player accelerates at `a_max` along the straight line to the
#' target, starting from the component of their velocity along that line
#' (v0, negative if moving away), up to `v_max`. Turning cost and
#' reaction time are ignored.
#'
#'   d_accel = (v_max^2 - v0^2) / (2 a_max)
#'   t_accel = (v_max - v0) / a_max
#'
#' If d <= d_accel, t = (-v0 + sqrt(v0^2 + 2 a_max d)) / a_max; otherwise
#' t = t_accel + (d - d_accel) / v_max. v0 is clamped to [-v_max, v_max]
#' because observed speeds can exceed `v_max`.
#'
#' @param x,y Player position.
#' @param vx,vy Player velocity components.
#' @param tx,ty Target position.
#' @param v_max Top speed, yd/s.
#' @param a_max Acceleration, yd/s^2.
#' @return Seconds, non-negative; 0 at the target, NA where velocity is
#'   NA.
time_to_point <- function(
  x,
  y,
  vx,
  vy,
  tx,
  ty,
  v_max = PLAYER_S_MAX,
  a_max = PLAYER_A_MAX
) {
  stopifnot(
    length(v_max) == 1,
    length(a_max) == 1,
    v_max > 0,
    a_max > 0
  )

  dx <- tx - x
  dy <- ty - y
  d <- sqrt(dx^2 + dy^2)
  d_safe <- dplyr::if_else(d == 0, NA_real_, d)

  v0 <- (vx * dx + vy * dy) / d_safe
  v0 <- pmin(pmax(v0, -v_max), v_max)

  d_accel <- (v_max^2 - v0^2) / (2 * a_max)
  t_accel <- (v_max - v0) / a_max

  t <- dplyr::if_else(
    d <= d_accel,
    (-v0 + sqrt(v0^2 + 2 * a_max * d)) / a_max,
    t_accel + (d - d_accel) / v_max
  )

  dplyr::if_else(d == 0, 0, t)
}


#' Ball flight time in seconds
#'
#' Negative values (arrival before the throw) are returned unchanged.
#'
#' @param f_throw,f_arrived Frame numbers.
ball_flight_time <- function(f_throw, f_arrived) {
  (f_arrived - f_throw) / TRACKING_HZ
}
