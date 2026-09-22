# R/geometry.R ---------------------------------------------------------
# Vector geometry for coverage features. Defines functions only — no
# library() calls, no side effects.
#
# PRECONDITION: every function here assumes coordinates have already
# passed through standardize_direction() in R/standardize.R, i.e. the
# offense always advances toward +x. Passing raw left-direction plays
# will produce mirrored leverage signs, and it will look plausible.
#
# ---- conventions ----------------------------------------------------
#
# COORDINATES. x runs 0..FIELD_LENGTH (120) along the direction of play;
# goal lines at x = 10 and x = 110. y runs 0..FIELD_WIDTH (53.333) across
# the field. After standardization, larger x is always downfield for the
# offense.
#
# ANGLES. Both `dir` (direction of motion) and `o` (body orientation) are
# degrees clockwise from +y, so dir = 0 is +y and dir = 90 is +x. This is
# the convention verified against frame-to-frame displacement in
# analysis/01_eda.qmd section 2.6 and recorded in notes/decisions.md. It
# is NOT the mathematical convention (counterclockwise from +x), so
# sin/cos are swapped relative to what muscle memory suggests.
#
# UNITS. Positions in yards, speeds in yd/s, accelerations in yd/s^2,
# times in seconds. Tracking is 10 Hz (TRACKING_HZ), so one frame is
# 0.1 s.
#
# MISSINGNESS. `dir` and `o` carry NA on a small number of rows (section
# 2.4). Every function here propagates NA rather than dropping or
# imputing; the decision about what to do with an NA-valued feature
# belongs to the feature script, not to the geometry.
#
# VECTORIZATION. Every function is componentwise arithmetic on vectors.
# Dot products are written out as a1*b1 + a2*b2 rather than constructed
# with c() and sum(), because c() on length-n inputs produces a single
# length-2n vector and sum() collapses across rows. These are called on a
# pairwise offense-by-defense table of roughly 700k rows, so no
# Vectorize(), no rowwise(), and if_else()/pmin()/pmax() rather than
# if/min/max.
#
# DIVISION BY ZERO. dplyr::if_else() evaluates both branches, so guarding
# a division with if_else(d == 0, NA_real_, x / d) still divides by zero
# and still warns. The pattern used throughout is to build a `d_safe`
# with NA in place of zero and divide by that instead.
#
# ---- dependencies ---------------------------------------------------

source(here::here("R", "constants.R"))

# time_to_point() defaults to PLAYER_S_MAX and PLAYER_A_MAX from
# R/constants.R. Those are attainable-performance estimates — the median
# across players of each player's own p999 of s and p99 of a — and NOT
# the pooled row-level p99, which is dominated by frames where players
# are standing or jogging and lands far too low.
#
# They are also NOT MAX_SPEED / MAX_ACCEL, which are implausibility
# thresholds for flagging corrupt rows. 13 yd/s is a defect boundary, not
# a speed anyone reaches. Do not reuse them here.

# ---- velocity --------------------------------------------------------

#' Decompose speed and direction into velocity components
#'
#' Because `dir` is clockwise from +y:
#'
#'   vx = s * sin(dir * pi / 180)
#'   vy = s * cos(dir * pi / 180)
#'
#' @param s Speed in yd/s.
#' @param dir Direction of motion, degrees clockwise from +y.
#' @return A list with numeric vectors `vx` and `vy`, same length as `s`.
velocity_xy <- function(s, dir) {
  rad <- dir * pi / 180
  list(vx = s * sin(rad), vy = s * cos(rad))
}


#' Bearing from one point to another, in the tracking angle convention
#'
#' Returns degrees clockwise from +y in [0, 360), directly comparable to
#' `dir` and `o`. atan2(dx, dy) rather than atan2(dy, dx) is what makes
#' it clockwise-from-+y instead of counterclockwise-from-+x.
#'
#' @param x,y Origin.
#' @param tx,ty Target.
#' @return Numeric vector of degrees in [0, 360). NA where the two points
#'   coincide, since the bearing is undefined.
bearing_to <- function(x, y, tx, ty) {
  dx <- tx - x
  dy <- ty - y
  deg <- atan2(dx, dy) * 180 / pi
  dplyr::if_else(dx == 0 & dy == 0, NA_real_, deg %% 360)
}


#' Signed smallest angle between two bearings
#'
#' Wraps to (-180, 180]. Used for "throwing across the body": the
#' difference between a quarterback's orientation `o` and the bearing to
#' the arrival point. Take abs() for magnitude; keep the sign if the
#' direction of the cross-body throw matters.
#'
#' @param a,b Bearings in degrees.
#' @return Numeric vector in (-180, 180].
angle_diff_deg <- function(a, b) {
  ((b - a + 180) %% 360) - 180
}


# ---- separation ------------------------------------------------------

#' Rate of change of the distance between two players
#'
#' The projection of relative velocity onto the unit separation vector:
#'
#'   d_dot = ((v_d - v_r) . (x_d - x_r)) / ||x_d - x_r||
#'
#' Computed analytically from s and dir rather than by differencing
#' positions across frames. It is less noisy, and it is defined at a
#' single frame — which matters because the throw frame can be the last
#' clean frame on a play, leaving no neighbour to difference against.
#'
#' SIGN: negative means the gap is closing (defender gaining on
#' receiver), positive means it is opening.
#'
#' This is the instantaneous rate along the line connecting the two
#' players, so a defender circling a receiver at constant radius returns
#' 0 despite moving fast. That is correct, but it means this is not a
#' proxy for how much the defender is moving — carry defender speed as a
#' separate feature.
#'
#' @param xr,yr Receiver position.
#' @param vxr,vyr Receiver velocity components.
#' @param xd,yd Defender position.
#' @param vxd,vyd Defender velocity components.
#' @return Numeric vector, yd/s. Negative = closing. NA where the two
#'   players are coincident, since the unit vector is undefined.
closing_speed <- function(xr, yr, vxr, vyr, xd, yd, vxd, vyd) {
  dx <- xd - xr
  dy <- yd - yr
  d <- sqrt(dx^2 + dy^2)
  d_safe <- dplyr::if_else(d == 0, NA_real_, d)

  ((vxd - vxr) * dx + (vyd - vyr) * dy) / d_safe
}


# ---- leverage --------------------------------------------------------

#' Rotate a defender's offset into the throwing-lane frame
#'
#' Given the lane from the ball at the throw (x0, y0) to the arrival
#' point (x1, y1), express the defender's offset *from the receiver* in
#' lane coordinates. With u the unit vector along the lane and
#' delta = x_d - x_r:
#'
#'   l_par  = delta . u
#'   l_perp = u_x * delta_y - u_y * delta_x
#'
#' l_perp is the z-component of the 2D cross product, which is what makes
#' it signed rather than a magnitude.
#'
#' INTERPRETATION:
#'   l_par < 0    defender is between QB and receiver (underneath, in the
#'                lane)
#'   l_par > 0    defender is playing over the top
#'   l_perp > 0   defender is to the left of the lane direction
#'   l_perp < 0   defender is to the right of the lane direction
#'
#' l_perp is LEFT/RIGHT relative to the lane, which is not the same as
#' INSIDE/OUTSIDE. Pass the result through to_inside_outside() if you
#' want the coverage-literature convention.
#'
#' The identity
#'
#'   l_par^2 + l_perp^2 = d^2
#'
#' holds exactly, where d is the receiver-defender distance. A model may
#' therefore use (l_par, l_perp) OR (d, angle), never both — including
#' all three gives exact collinearity and glm() returns rank deficiency.
#' Worth an assertion in the feature script.
#'
#' @param x0,y0 Lane origin — ball position at the throw.
#' @param x1,y1 Lane endpoint — arrival point, or receiver position for
#'   the notional-target robustness variant.
#' @param xd,yd Defender position.
#' @param xr,yr Receiver position.
#' @return A list with numeric vectors `l_par` and `l_perp`. Both NA
#'   where the lane has zero length, since u is undefined.
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
#' "Inside" means toward the middle of the field. Which sign of l_perp
#' that corresponds to depends on which side of the field the receiver is
#' aligned on, so the conversion needs the receiver's y.
#'
#' Exact only for a lane pointing straight downfield; lanes with a large
#' lateral component make left/right and inside/outside diverge. Since
#' throws beyond the line of scrimmage point generally downfield, the
#' approximation is close. Say so in Methods rather than implying the
#' mapping is exact.
#'
#' @param l_perp Signed lateral offset from rotate_to_lane().
#' @param yr Receiver y at the throw.
#' @param midline Field centre. Defaults to FIELD_WIDTH / 2 (26.667).
#' @return Numeric vector. Positive = defender inside the receiver
#'   (toward the middle of the field), negative = outside.
to_inside_outside <- function(l_perp, yr, midline = FIELD_WIDTH / 2) {
  dplyr::if_else(yr <= midline, l_perp, -l_perp)
}


# ---- passing window --------------------------------------------------

#' Perpendicular distance from a point to a line segment
#'
#' For the throw corridor: how far off the ball's path a defender sits,
#' and how far along that path they sit.
#'
#' The projection parameter is clamped to [0, 1]. Unclamped, this
#' measures distance to the infinite line, so a defender standing behind
#' the quarterback or well beyond the arrival point reports a small
#' perpendicular distance and looks like a threat in the passing window.
#' Clamped, they correctly report distance to the nearer endpoint.
#'
#' `t_raw` is returned unclamped because the two ends mean different
#' things: t_raw < 0 is a defender behind the throw, t_raw > 1 is a
#' defender past the arrival point.
#'
#' A degenerate segment (origin == endpoint) falls out correctly without
#' a special case: the lane vector is zero, t is 0, and the closest point
#' is the origin, so perp_dist is the distance from p to the origin.
#'
#' @param x0,y0 Segment start — ball at the throw.
#' @param x1,y1 Segment end — arrival point.
#' @param px,py Point to measure — defender position.
#' @return A list with numeric vectors `perp_dist` (yards), `t_along`
#'   (clamped to [0, 1]) and `t_raw` (unclamped, NA on a degenerate
#'   segment).
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

#' Time for a player to reach a target point
#'
#' A minimal motion model: the player accelerates at a_max along the
#' straight line toward the target, starting from the component of their
#' current velocity in that direction, and is capped at v_max. Turning
#' cost is ignored, which makes this optimistic for a player moving
#' laterally or away — the main simplification, and one for Methods.
#'
#' Let d be the distance to the target, u the unit vector toward it, and
#' v0 = v . u the initial speed along that line, negative if moving away.
#' Two regimes, with the boundary at the distance covered while
#' accelerating from v0 to v_max:
#'
#'   d_accel = (v_max^2 - v0^2) / (2 a_max)
#'   t_accel = (v_max - v0) / a_max
#'
#' If d <= d_accel the target is reached while still accelerating, and t
#' is the positive root of (1/2) a_max t^2 + v0 t - d = 0:
#'
#'   t = (-v0 + sqrt(v0^2 + 2 a_max d)) / a_max
#'
#' Otherwise t = t_accel + (d - d_accel) / v_max.
#'
#' The displacement formula v0*t + (1/2)a*t^2 handles a negative v0
#' correctly on its own: the player decelerates, reverses, and the net
#' displacement at t_accel is still d_accel >= 0. Clamping |v0| <= v_max
#' is what guarantees d_accel >= 0 and t_accel >= 0, and it is needed
#' because v_max is a p99 rather than a hard ceiling — roughly 1% of rows
#' legitimately exceed it.
#'
#' No reaction-time constant. The pitch-control literature includes one,
#' but here the player is already reacting to a throw in flight, so
#' adding one arguably double-counts. Noted as a choice.
#'
#' @param x,y Player position.
#' @param vx,vy Player velocity components.
#' @param tx,ty Target position — the arrival point.
#' @param v_max Attainable top speed, yd/s.
#' @param a_max Attainable acceleration, yd/s^2.
#' @return Numeric vector of times in seconds, non-negative. 0 where the
#'   player is already at the target. NA where velocity is NA.
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

  # Speed component along the line to the target. Negative = moving away.
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
#' Named so the TRACKING_HZ division happens in one place and the feature
#' script reads as `tau_def - ball_flight_time(...)` rather than as
#' arithmetic.
#'
#' Negative values are returned as-is rather than coerced to NA. The
#' `timing-anomalies` chunk in analysis/01_eda.qmd counts plays where
#' arrival precedes the throw; silently absorbing them here would hide a
#' data problem that the sample rule should be handling.
#'
#' @param f_throw,f_arrived Frame numbers of the throw and the arrival.
#' @return Numeric vector of seconds.
ball_flight_time <- function(f_throw, f_arrived) {
  (f_arrived - f_throw) / TRACKING_HZ
}
