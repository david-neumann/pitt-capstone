# R/constants.R --------------------------------------------------------
# Field geometry and physical bounds. Single source of truth — sourced by
# R/standardize.R, R/viz.R, R/geometry.R and the build scripts so the numbers can't
# drift apart.

# ---- field geometry, in yards ----------------------------------------

# Length includes both 10-yard end zones. Goal lines at x = 10 and 110.
FIELD_LENGTH <- 120

# 160 feet.
FIELD_WIDTH <- 160 / 3 # 53.3333

# NFL inbound lines ("hash marks") sit 70'9" from each sideline, which
# puts the two rows 18'6" apart. College hashes are 40 ft apart and much
# closer to the sidelines — do not reuse college field code here.
HASH_INSET <- 70.75 / 3 # 23.5833
HASH_Y <- c(HASH_INSET, FIELD_WIDTH - HASH_INSET) # 23.5833, 29.75

# Hash marks and sideline ticks are 24 inches long.
MARK_LEN <- 2 / 3

# Tracking data is captured at 10 Hz.
TRACKING_HZ <- 10

# ---- kinematic plausibility bounds -----------------------------------
# These were defined inline in analysis/01_eda.qmd. They now live here
# because scripts/03_build_play_index.R flags defective rows with them,
# and a threshold that differs between the build script and the notebook
# would make the two disagree about which plays are clean.
#
# These are the one judgment call in the play index. They are recoverable:
# raw s, a, and dis stay in data/processed/tracking, and the row-level
# defect table is rebuilt from scratch on every run of 03.

# Elite human top speed is about 10.5 yd/s, so anything above 13 is not a
# football player.
MAX_SPEED <- 13 # yd/s

# Per-frame displacement is bounded by the same speed over a 0.1 s frame.
MAX_DIS <- MAX_SPEED / TRACKING_HZ # yd per frame

MAX_ACCEL <- 20 # yd/s^2

# ---- player motion model ---------------------------------------------
# Inputs to time_to_point() in R/geometry.R. Distinct from MAX_SPEED /
# MAX_ACCEL above, which are *implausibility* thresholds for flagging
# corrupt rows. These are attainable-performance estimates.
#
# Estimated from the tracking data itself rather than from outside
# literature: per-player p999 of s and p99 of a, restricted to players
# with >= 5000 tracked rows and to rows passing the defect thresholds,
# then the median across players. Query in notes/decisions.md.
#
#   s: per-player p999, median across players  9.22   (p90: 9.98)
#   a: per-player p99,  median across players  5.90   (p90: 6.50)

PLAYER_S_MAX <- 9.22 # yd/s
PLAYER_A_MAX <- 5.90 # yd/s^2

# ---- arrival detection -----------------------------------------------
# Arrival is the last frame the ball is still unambiguously in flight,
# searched back from the frame of closest approach to the targeted
# receiver. See notes/decisions.md §6 and analysis/02_arrival_anchor.qmd.
#
# DIS_FLIGHT equals MAX_DIS BY ARGUMENT, not by coincidence: MAX_DIS is
# the per-frame displacement no *player* can exceed, so a ball above it
# cannot be in anyone's hands. Verified against the bimodal distribution
# of ball `dis` over the search window — carry and dead ball below ~1.0,
# flight at ~2.1, valley floor around 1.0-1.2 yd/frame. Sensitivity: 87%
# frame agreement at 1.0, 82% at 1.6, median shift 0 frames.
#
# If MAX_DIS is ever revised, revisit this alias rather than inheriting
# the change silently.
DIS_FLIGHT <- MAX_DIS

# Flight-speed runs separated by fewer than this many frames are treated
# as one run. A single frame of jitter on a wobbling ball dips below
# DIS_FLIGHT mid-flight; ending the flight there is wrong. The two
# extremes disagree on 92 of 890 week-1 plays (median gap 2 frames, max
# 37), so neither 0 nor unbounded is right. Set from the sensitivity
# table in analysis/02_arrival_anchor.qmd section 7.4.
ARRIVAL_GAP_TOL <- 2L

# Search window. Observed flight-time p99 is under 3.5 s; the cap only
# bounds pathological cases.
MAX_FLIGHT_FRAMES <- 50L
