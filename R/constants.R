# R/constants.R --------------------------------------------------------
# Field geometry, in yards. Single source of truth — sourced by both
# R/standardize.R and R/viz.R so the numbers can't drift apart.

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
