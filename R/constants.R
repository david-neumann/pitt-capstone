# R/constants.R --------------------------------------------------------
# Field geometry, physical bounds, and detection parameters shared by the
# build scripts, R/ helpers, and notebooks.

# ---- field geometry, in yards ----------------------------------------

# Includes both 10-yard end zones; goal lines at x = 10 and x = 110.
FIELD_LENGTH <- 120

# 160 feet.
FIELD_WIDTH <- 160 / 3 # 53.3333

# NFL hash marks sit 70'9" from each sideline (18'6" apart). College
# hashes differ.
HASH_INSET <- 70.75 / 3 # 23.5833
HASH_Y <- c(HASH_INSET, FIELD_WIDTH - HASH_INSET) # 23.5833, 29.75

# Hash marks and sideline ticks are 24 inches long.
MARK_LEN <- 2 / 3

TRACKING_HZ <- 10

# ---- kinematic plausibility bounds -----------------------------------
# Rows exceeding these are flagged as defects by
# scripts/03_build_play_index.R. Raw s, a, and dis are kept, so changing
# a threshold only requires re-running 03.

# Elite top speed is about 10.5 yd/s.
MAX_SPEED <- 13 # yd/s

MAX_DIS <- MAX_SPEED / TRACKING_HZ # yd per frame

MAX_ACCEL <- 20 # yd/s^2

# ---- player motion model ---------------------------------------------
# Defaults for time_to_point() in R/geometry.R. These are attainable-
# performance estimates, not the defect thresholds above.
#
# Estimated from the tracking data: per-player p999 of s and p99 of a,
# restricted to players with >= 5000 rows and to rows passing the defect
# thresholds, then the median across players.
#
#   s: per-player p999, median across players  9.22   (p90: 9.98)
#   a: per-player p99,  median across players  5.90   (p90: 6.50)

PLAYER_S_MAX <- 9.22 # yd/s
PLAYER_A_MAX <- 5.90 # yd/s^2

# ---- arrival detection -----------------------------------------------
# See R/arrival.R and notes/decisions.md §6.

# Minimum ball displacement per frame that counts as flight. Tied to
# MAX_DIS deliberately: no player can move faster, so a ball above it is
# not being carried. Revisit this alias if MAX_DIS changes.
DIS_FLIGHT <- MAX_DIS

# Flight-speed runs separated by at most this many frames are merged,
# so one frame of jitter mid-flight does not end the flight. Chosen from
# the sensitivity table in analysis/02_arrival_anchor.qmd §7.4.
ARRIVAL_GAP_TOL <- 2L

# Search window after the throw. Observed flight-time p99 is under 3.5 s.
MAX_FLIGHT_FRAMES <- 50L
