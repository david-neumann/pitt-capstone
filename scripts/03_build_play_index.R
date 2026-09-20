# scripts/03_build_play_index.R ----------------------------------------
# Reduce 18.3M tracking rows to one row per play and one row per
# (play, player).
#
# SCOPE: measured facts only. Nothing here drops a play, and nothing here
# is a modeling choice. Every column answers a question of the form "what
# is true of this play in the data", never "should this play be kept".
# That distinction is the whole point of the file: the exclusion rule in
# scripts/04_build_sample.R reads these columns, and the notebook reports
# them, so neither has to rescan the tracking data or hold intermediate
# objects alive to stay consistent.
#
# The one judgment call is the kinematic thresholds, which live in
# R/constants.R. The row-level defect table is rebuilt from raw s / a /
# dis on every run, so changing a threshold is a re-run of this script.
#
# Outputs, all in data/processed/:
#   player_play_index.parquet  one row per (play, player)
#   play_index.parquet         one row per play
#   play_events.parquet        one row per (play, frame, event)
#   kinematic_defects.parquet  one row per defective tracking row
#
# Run after 02_build_canonical.R, before 04_build_sample.R.
# Expect several minutes: six narrow scans of the tracking dataset.

library(arrow)
library(dplyr)
library(tidyr)
library(purrr)
library(fs)
library(here)

source(here("R", "constants.R"))
source(here("R", "utils.R"))

processed <- here("data", "processed")

trk <- open_dataset(path(processed, "tracking"))
plays <- read_parquet(path(processed, "plays.parquet"))
targets <- read_parquet(path(processed, "targeted_receiver.parquet"))

#' Events worth pinning a frame number to
#'
#' pass_shovel and pass_lateral are here because some recorded pass
#' attempts carry no pass_forward event at all; the throw on those plays
#' is labeled differently. Whether to accept them as a throw anchor is a
#' decision, and it lives in R/sample_rules.R, not here.
ANCHOR_EVENTS <- c(
  "ball_snap",
  "pass_forward",
  "pass_shovel",
  "pass_lateral",
  "pass_arrived",
  "pass_tipped",
  "pass_outcome_caught",
  "pass_outcome_incomplete",
  "pass_outcome_interception",
  "pass_outcome_touchdown",
  "qb_sack",
  "qb_strip_sack",
  "fumble",
  "out_of_bounds",
  "tackle"
)

# Events whose multiplicity matters: min() silently takes the first of
# several, and where a play has more than one forward pass, "first" may be
# the wrong one.
COUNTED_EVENTS <- c("ball_snap", "pass_forward", "pass_arrived")

# ---- pass 1: player-level frame spans, position, side, route ----------
# Grouping by side / position / route rather than aggregating them asserts
# that they are constant within a player-play: if any varied, the key
# below would be non-unique and the stopifnot() would fire.

message("[1/6] player frame spans")

player_play <- trk |>
  filter(!is_ball) |>
  group_by(game_id, play_id, nfl_id, side, position, route) |>
  summarize(
    min_frame = min(frame_id),
    max_frame = max(frame_id),
    n_rows = n(),
    .groups = "drop"
  ) |>
  collect() |>
  cast_keys() |>
  mutate(
    # n_rows rather than n_distinct(frame_id): on a deduplicated build the
    # two are equal, so this test fails for a surplus row as readily as
    # for a missing one. A negative frames_lost downstream means
    # duplication was reintroduced upstream.
    span = max_frame - min_frame + 1L,
    gapless = n_rows == span,
    starts_at_one = min_frame == 1L
  ) |>
  arrange(game_id, play_id, nfl_id)

stopifnot(
  anyDuplicated(player_play[c("game_id", "play_id", "nfl_id")]) == 0,
  !anyNA(player_play$side)
)

write_parquet(player_play, path(processed, "player_play_index.parquet"))

# ---- pass 2: play-level row and frame counts -------------------------

message("[2/6] play row and frame counts")

play_rows <- trk |>
  filter(!is_ball) |>
  group_by(game_id, play_id) |>
  summarize(
    n_rows = n(),
    n_frames = n_distinct(frame_id),
    .groups = "drop"
  ) |>
  collect() |>
  cast_keys()

# ---- pass 3: ball coverage -------------------------------------------

message("[3/6] ball coverage")

ball_frames <- trk |>
  filter(is_ball) |>
  group_by(game_id, play_id) |>
  summarize(n_ball_frames = n_distinct(frame_id), .groups = "drop") |>
  collect() |>
  cast_keys()

# ---- pass 4: key uniqueness tripwire ---------------------------------
# 02_build_canonical.R deduplicates and asserts, so this should return
# nothing. It stays as a tripwire: a nonzero count means the cleaning step
# regressed. Ball rows carry nfl_id = NA, so this also covers "exactly one
# ball row per frame".

message("[4/6] duplicate key tripwire")

dup_keys <- trk |>
  count(game_id, play_id, nfl_id, frame_id) |>
  filter(n > 1) |>
  collect() |>
  cast_keys()

if (nrow(dup_keys)) {
  warning(
    nrow(dup_keys),
    " duplicated (play, player, frame) keys survive the canonical build.",
    call. = FALSE
  )
}

dup_rollup <- dup_keys |>
  distinct(game_id, play_id) |>
  mutate(has_duplicate_rows = TRUE)

# ---- pass 5: event timeline ------------------------------------------
# `event` is populated on every row of the frame in which the event
# occurs, so deduplicate to the frame level before counting.

message("[5/6] event timeline")

play_events <- trk |>
  filter(!is.na(event)) |>
  distinct(game_id, play_id, frame_id, event) |>
  collect() |>
  cast_keys() |>
  arrange(game_id, play_id, frame_id)

write_parquet(play_events, path(processed, "play_events.parquet"))

event_agg <- play_events |>
  filter(event %in% ANCHOR_EVENTS) |>
  group_by(game_id, play_id, event) |>
  summarize(frame = min(frame_id), n = n(), .groups = "drop")

first_frames <- event_agg |>
  select(game_id, play_id, event, frame) |>
  pivot_wider(names_from = event, values_from = frame, names_prefix = "f_") |>
  ensure_cols(paste0("f_", ANCHOR_EVENTS))

event_counts <- event_agg |>
  filter(event %in% COUNTED_EVENTS) |>
  select(game_id, play_id, event, n) |>
  pivot_wider(names_from = event, values_from = n, names_prefix = "n_ev_") |>
  ensure_cols(paste0("n_ev_", COUNTED_EVENTS))

# ---- pass 6: kinematic defects ---------------------------------------

message("[6/6] kinematic defects")

defects <- trk |>
  filter(!is_ball) |>
  filter(
    s > MAX_SPEED |
      dis > MAX_DIS |
      a > MAX_ACCEL |
      dir < 0 |
      dir >= 360 |
      o < 0 |
      o >= 360
  ) |>
  select(
    game_id,
    play_id,
    week,
    frame_id,
    nfl_id,
    position,
    side,
    x,
    y,
    s,
    a,
    dis,
    dir,
    o
  ) |>
  collect() |>
  cast_keys()

defects <- defects |>
  left_join(
    select(first_frames, game_id, play_id, f_ball_snap, f_pass_forward),
    by = c("game_id", "play_id")
  ) |>
  mutate(
    which = case_when(
      s > MAX_SPEED ~ "speed",
      dis > MAX_DIS ~ "displacement",
      a > MAX_ACCEL ~ "acceleration",
      .default = "angle"
    ),
    position_in_play = case_when(
      is.na(f_ball_snap) ~ "no snap event",
      frame_id < f_ball_snap ~ "pre-snap",
      is.na(f_pass_forward) ~ "post-snap, no throw",
      frame_id <= f_pass_forward ~ "snap to throw",
      .default = "after throw"
    )
  )

write_parquet(defects, path(processed, "kinematic_defects.parquet"))

defect_rollup <- defects |>
  group_by(game_id, play_id) |>
  summarize(
    n_defect_rows = n(),
    n_defect_rows_in_window = sum(position_in_play == "snap to throw"),
    .groups = "drop"
  ) |>
  mutate(
    has_kinematic_defect = TRUE,
    defect_in_window = n_defect_rows_in_window > 0
  )

# ---- rollups from the player-level table -----------------------------
# side counts, route counts, and gap counts all come off player_play
# rather than from further scans of the tracking data.

player_rollup <- player_play |>
  group_by(game_id, play_id) |>
  summarize(
    n_players = n(),
    first_frame = min(min_frame),
    last_frame = max(max_frame),
    n_distinct_last = n_distinct(max_frame),
    n_gapped = sum(!gapless),
    n_not_starting_at_one = sum(!starts_at_one),
    # route is NA for every defender, so this is an offense-only count
    # without needing a side filter.
    n_routes = sum(!is.na(route)),
    .groups = "drop"
  )

side_counts <- player_play |>
  count(game_id, play_id, side) |>
  pivot_wider(
    names_from = side,
    values_from = n,
    values_fill = 0L,
    names_prefix = "n_"
  ) |>
  ensure_cols(c("n_offense", "n_defense"), fill = 0L)

target_status <- targets |>
  select(game_id, play_id, target_nfl_id) |>
  cast_keys() |>
  left_join(
    player_play |>
      filter(side == "offense") |>
      distinct(game_id, play_id, nfl_id) |>
      mutate(target_tracked = TRUE),
    by = c("game_id", "play_id", "target_nfl_id" = "nfl_id")
  ) |>
  mutate(target_tracked = coalesce(target_tracked, FALSE))

# ---- assemble the play index -----------------------------------------

play_index <- play_rows |>
  left_join(player_rollup, by = c("game_id", "play_id")) |>
  left_join(side_counts, by = c("game_id", "play_id")) |>
  left_join(ball_frames, by = c("game_id", "play_id")) |>
  left_join(dup_rollup, by = c("game_id", "play_id")) |>
  left_join(first_frames, by = c("game_id", "play_id")) |>
  left_join(event_counts, by = c("game_id", "play_id")) |>
  left_join(defect_rollup, by = c("game_id", "play_id")) |>
  left_join(target_status, by = c("game_id", "play_id")) |>
  mutate(
    n_ball_frames = coalesce(n_ball_frames, 0L),
    has_duplicate_rows = coalesce(has_duplicate_rows, FALSE),
    has_kinematic_defect = coalesce(has_kinematic_defect, FALSE),
    defect_in_window = coalesce(defect_in_window, FALSE),
    n_defect_rows = coalesce(n_defect_rows, 0L),
    n_defect_rows_in_window = coalesce(n_defect_rows_in_window, 0L),
    target_tracked = coalesce(target_tracked, FALSE),
    across(starts_with("n_ev_"), \(x) coalesce(x, 0L)),

    ball_status = case_when(
      n_ball_frames == 0 ~ "no ball tracked",
      n_ball_frames < n_frames ~ "ball partially tracked",
      n_ball_frames == n_frames ~ "complete",
      .default = "more ball frames than play frames"
    ),

    # The row-count identity n_rows = n_players * n_frames can fail two
    # ways, and a within-player gap check only sees one of them: a player
    # who drops out at frame 40 while everyone else runs to frame 60 is
    # gapless, starts at frame one, and still breaks the identity.
    ragged = n_rows != n_players * n_frames,
    frames_lost = n_players * n_frames - n_rows,
    ragged_cause = case_when(
      !ragged ~ "rectangular",
      n_gapped > 0 & n_distinct_last > 1 ~ "both",
      n_gapped > 0 ~ "internal gaps",
      n_distinct_last > 1 ~ "uneven endpoints",
      .default = "unexplained"
    )
  ) |>
  relocate(n_players, .after = play_id) |>
  arrange(game_id, play_id)

# ---- integrity checks ------------------------------------------------
# These were five rows of a gt() table in the notebook. They belong here:
# a join that silently matches nothing should stop the build, not produce
# a zero in a document nobody rereads.

players_tbl <- read_parquet(path(processed, "players.parquet"))

integrity <- tibble(
  check = c(
    "duplicated play keys in play_index",
    "tracking nfl_id absent from players",
    "players never appearing in tracking",
    "tracking plays absent from plays table",
    "plays table entries absent from tracking",
    "plays with zero tracked players"
  ),
  n = c(
    sum(duplicated(play_index[c("game_id", "play_id")])),
    nrow(anti_join(
      distinct(player_play, nfl_id),
      distinct(players_tbl, nfl_id),
      by = "nfl_id"
    )),
    nrow(anti_join(
      distinct(players_tbl, nfl_id),
      distinct(player_play, nfl_id),
      by = "nfl_id"
    )),
    nrow(anti_join(
      distinct(play_index, game_id, play_id),
      distinct(plays, game_id, play_id),
      by = c("game_id", "play_id")
    )),
    nrow(anti_join(
      distinct(plays, game_id, play_id),
      distinct(play_index, game_id, play_id),
      by = c("game_id", "play_id")
    )),
    sum(coalesce(play_index$n_players, 0L) == 0)
  )
)

print(as.data.frame(integrity))

if (any(integrity$n > 0)) {
  warning(
    "Integrity checks are nonzero. These were all zero as of the week-4 ",
    "build; investigate before trusting the sample.",
    call. = FALSE
  )
}

write_parquet(play_index, path(processed, "play_index.parquet"))

message(
  "Done. ",
  nrow(play_index),
  " plays indexed; ",
  nrow(player_play),
  " player-plays; ",
  nrow(defects),
  " defective rows."
)
