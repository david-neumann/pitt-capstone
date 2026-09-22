source(here::here("R", "geometry.R"))

# ---- sanity checks ---------------------------------------------------
# Run these once after sourcing, before building any features. They
# catch the sign and convention errors that otherwise surface as a model
# that fits but means nothing.
#
# Note the 3-4-5 triangles: a check with one component zero passes under
# several plausible mis-parenthesizations of the norm, so every distance
# check below has both components nonzero.
#
stopifnot(
  # --- velocity_xy: dir is clockwise from +y
  all.equal(velocity_xy(5, 0)$vy, 5),
  all.equal(velocity_xy(5, 0)$vx, 0),
  all.equal(velocity_xy(5, 90)$vx, 5),
  all.equal(velocity_xy(5, 90)$vy, 0),
  all.equal(velocity_xy(5, 180)$vy, -5),

  # --- bearing_to: same convention
  all.equal(bearing_to(0, 0, 0, 1), 0),
  all.equal(bearing_to(0, 0, 1, 0), 90),
  all.equal(bearing_to(0, 0, 0, -1), 180),

  # --- angle_diff_deg: wraps the short way
  all.equal(angle_diff_deg(350, 10), 20),
  all.equal(angle_diff_deg(10, 350), -20),

  # --- closing_speed: negative = closing, 3-4-5 geometry
  #     receiver at origin stationary, defender at (3, 4) closing along
  #     the line at 5 yd/s -> -5
  all.equal(
    closing_speed(0, 0, 0, 0, 3, 4, -3, -4),
    -5
  ),
  #     same geometry, defender retreating -> +5
  all.equal(
    closing_speed(0, 0, 0, 0, 3, 4, 3, 4),
    5
  ),
  #     defender moving perpendicular to the line -> 0
  all.equal(
    closing_speed(0, 0, 0, 0, 3, 4, 4, -3),
    0
  ),
  #     coincident players -> NA
  is.na(closing_speed(0, 0, 0, 0, 0, 0, 1, 1)),

  # --- rotate_to_lane
  #     lane from (0,0) to (10,0); receiver at (10,0); defender at
  #     (6,0) is 4 yd underneath, dead in the lane
  all.equal(rotate_to_lane(0, 0, 10, 0, 6, 0, 10, 0)$l_par, -4),
  all.equal(rotate_to_lane(0, 0, 10, 0, 6, 0, 10, 0)$l_perp, 0),
  #     defender on the receiver -> both zero
  all.equal(rotate_to_lane(0, 0, 10, 0, 10, 0, 10, 0)$l_par, 0),
  all.equal(rotate_to_lane(0, 0, 10, 0, 10, 0, 10, 0)$l_perp, 0),
  #     the exact identity, on random inputs
  local({
    set.seed(1961)
    n <- 500
    a <- matrix(runif(6 * n, 0, 50), ncol = 6)
    r <- rotate_to_lane(
      a[, 1],
      a[, 2],
      a[, 3],
      a[, 4],
      a[, 5],
      a[, 6],
      a[, 1] + 1,
      a[, 2] + 1
    )
    d2 <- (a[, 5] - (a[, 1] + 1))^2 + (a[, 6] - (a[, 2] + 1))^2
    isTRUE(all.equal(r$l_par^2 + r$l_perp^2, d2))
  }),

  # --- to_inside_outside: flips with the receiver's side of the field
  all.equal(to_inside_outside(3, 5), 3),
  all.equal(to_inside_outside(3, 48), -3),

  # --- point_to_segment: clamping is the thing being tested
  #     point on the segment
  all.equal(point_to_segment(0, 0, 10, 0, 5, 0)$perp_dist, 0),
  all.equal(point_to_segment(0, 0, 10, 0, 5, 0)$t_along, 0.5),
  #     point beyond the far end -> t = 1, distance to that endpoint
  all.equal(point_to_segment(0, 0, 10, 0, 14, 3)$t_along, 1),
  all.equal(point_to_segment(0, 0, 10, 0, 14, 3)$perp_dist, 5),
  #     point behind the origin -> t = 0, distance to the origin
  all.equal(point_to_segment(0, 0, 10, 0, -4, 3)$t_along, 0),
  all.equal(point_to_segment(0, 0, 10, 0, -4, 3)$perp_dist, 5),
  #     t_raw keeps the sign the clamp discards
  point_to_segment(0, 0, 10, 0, -4, 3)$t_raw < 0,
  #     degenerate segment
  all.equal(point_to_segment(0, 0, 0, 0, 3, 4)$perp_dist, 5),

  # --- time_to_point
  #     already there
  all.equal(time_to_point(0, 0, 0, 0, 0, 0, 9, 7), 0),
  #     from rest, short enough to stay in the acceleration phase:
  #     d = 3.5, a = 7 -> t = sqrt(2d/a) = 1
  all.equal(time_to_point(0, 0, 0, 0, 3.5, 0, 9, 7), 1),
  #     moving away is strictly slower than moving toward
  time_to_point(0, 0, -5, 0, 20, 0, 9, 7) >
    time_to_point(0, 0, 5, 0, 20, 0, 9, 7),
  #     monotone in distance
  !is.unsorted(time_to_point(0, 0, 0, 0, seq(1, 40, by = 1), 0, 9, 7)),
  #     v0 above the cap does not produce a negative time
  time_to_point(0, 0, 12, 0, 20, 0, 9, 7) > 0,
  #     NA velocity propagates
  is.na(time_to_point(0, 0, NA_real_, 0, 20, 0, 9, 7)),

  # --- ball_flight_time
  all.equal(ball_flight_time(30L, 45L), 1.5)
)
