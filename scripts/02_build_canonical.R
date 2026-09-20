# scripts/02_build_canonical.R -----------------------------------------
# interim -> processed. Cleaning, naming, and coordinate standardization.
#
# SCOPE: this script makes no analytical decisions and drops no plays. It
# renames, deduplicates exactly-identical rows, derives is_ball / side /
# team_abbr, rotates left-moving plays into a single coordinate frame, and
# casts every identifier to int32. Anything that constitutes a modeling
# choice lives downstream: exclusions in scripts/04_build_sample.R,
# coverage collapsing in R/coverage.R.
#
# Run after 01_raw_to_parquet.R, before 03_build_play_index.R.

library(arrow)
library(dplyr)
library(fs)
library(here)

source(here("R", "constants.R"))
source(here("R", "utils.R"))
source(here("R", "standardize.R"))
source(here("R", "coverage.R"))

interim <- here("data", "interim")
processed <- here("data", "processed")
dir_create(path(processed, "tracking"))

require_cols <- function(df, cols, what) {
  missing <- setdiff(cols, names(df))
  if (length(missing)) {
    stop(what, " missing expected columns: ", paste0(missing, collapse = ", "))
  }
  invisible(df)
}

# --- games ------------------------------------------------------------

games <- read_parquet(path(interim, "games.parquet")) |>
  rename_with(to_snake)

require_cols(
  games,
  c("game_id", "home_team_abbr", "visitor_team_abbr", "week"),
  "games"
)

# A duplicated game_id would fan out every downstream left_join.
stopifnot(!any(duplicated(games$game_id)))

game_teams <- games |>
  rename(home_team = home_team_abbr, away_team = visitor_team_abbr) |>
  cast_keys()

write_parquet(game_teams, path(processed, "games.parquet"))

# --- one play_direction per play --------------------------------------

trk_raw <- open_dataset(path(interim, "tracking"))

play_dir <- trk_raw |>
  select(gameId, playId, playDirection) |>
  distinct() |>
  collect() |>
  rename(
    game_id = gameId,
    play_id = playId,
    play_direction = playDirection
  ) |>
  cast_keys()

# A play must have exactly one play direction, or standardization is
# ill-defined for it.
stopifnot(!any(duplicated(play_dir[c("game_id", "play_id")])))

# --- plays ------------------------------------------------------------

plays <- read_parquet(path(interim, "plays.parquet")) |>
  rename_with(to_snake) |>
  cast_keys()

require_cols(
  plays,
  c("game_id", "play_id", "possession_team", "absolute_yardline_number"),
  "plays"
)

plays <- plays |>
  left_join(play_dir, by = c("game_id", "play_id")) |>
  # Only the columns the rest of the project reads. Joining all of
  # game_teams left plays.parquet carrying game_date, game_time_eastern,
  # and a redundant copy of every abbreviation column.
  left_join(
    select(game_teams, game_id, week, home_team, away_team),
    by = "game_id"
  ) |>
  mutate(
    defense_team = if_else(possession_team == home_team, away_team, home_team),
    los_x = standardize_los(absolute_yardline_number, play_direction)
  )

stopifnot(!anyNA(plays$play_direction))

# side_lookup is joined onto 18.3M tracking rows below, so a duplicated
# play key here would double those rows silently.
stopifnot(!any(duplicated(plays[c("game_id", "play_id")])))

write_parquet(plays, path(processed, "plays.parquet"))

# --- players ----------------------------------------------------------

players <- read_parquet(path(interim, "players.parquet")) |>
  rename_with(to_snake) |>
  cast_keys()

stopifnot(!any(duplicated(players$nfl_id)))

write_parquet(players, path(processed, "players.parquet"))

# --- targeted receiver ------------------------------------------------

targeted <- read_parquet(path(interim, "targetedReceiver.parquet")) |>
  rename_with(to_snake) |>
  cast_keys()

require_cols(
  targeted,
  c("game_id", "play_id", "target_nfl_id"),
  "targetedReceiver"
)
stopifnot(!any(duplicated(targeted[c("game_id", "play_id")])))

write_parquet(targeted, path(processed, "targeted_receiver.parquet"))

# --- coverages (week 1 only) ------------------------------------------
# The eight labels are written through verbatim. Collapsing them to the
# man/zone binary is a modeling decision and happens in
# scripts/04_build_sample.R via classify_coverage(). What this script does
# is assert that every label still maps, so a vocabulary change is a
# build-time error rather than a silent NA downstream.

coverages <- read_parquet(path(interim, "coverages_week1.parquet")) |>
  rename_with(to_snake) |>
  cast_keys()

require_cols(coverages, c("game_id", "play_id", "coverage"), "coverages_week1")
stopifnot(!any(duplicated(coverages[c("game_id", "play_id")])))

assert_coverage_vocabulary(coverages$coverage)

write_parquet(coverages, path(processed, "coverages_week1.parquet"))

# --- tracking, one week at a time -------------------------------------

side_lookup <- plays |>
  select(game_id, play_id, possession_team, home_team, away_team)

# The raw week files contain exactly-duplicated rows on a small number of
# plays. Deduplication happens here rather than in 01_raw_to_parquet.R so
# the interim layer stays a faithful copy of the source CSVs.
dedup_log <- tibble(
  week = integer(),
  rows_in = integer(),
  rows_out = integer()
)

week_keys <- vector("list", 17)

for (w in 1:17) {
  message("Canonicalizing week ", w)

  trk_week <- trk_raw |>
    filter(week == w) |>
    collect() |>
    rename_with(to_snake) |>
    cast_keys()

  n_in <- nrow(trk_week)
  trk_week <- distinct(trk_week)

  dedup_log <- bind_rows(
    dedup_log,
    tibble(week = w, rows_in = n_in, rows_out = nrow(trk_week))
  )

  trk_week <- trk_week |>
    left_join(side_lookup, by = c("game_id", "play_id")) |>
    mutate(
      is_ball = team == "football",
      team_abbr = case_when(
        team == "home" ~ home_team,
        team == "away" ~ away_team,
        .default = NA_character_
      ),
      # The NA branch is explicit so an unresolvable row surfaces as NA
      # and trips the assertion below, rather than falling through to
      # "defense".
      side = case_when(
        is_ball ~ "ball",
        is.na(team_abbr) | is.na(possession_team) ~ NA_character_,
        team_abbr == possession_team ~ "offense",
        .default = "defense"
      ),
      event = if_else(event == "None", NA_character_, event)
    ) |>
    standardize_direction() |>
    select(
      game_id,
      play_id,
      week,
      frame_id,
      nfl_id,
      display_name,
      position,
      jersey_number,
      team_abbr,
      side,
      is_ball,
      x,
      y,
      s,
      a,
      dis,
      o,
      dir,
      event,
      route,
      time,
      play_direction
    )

  # Full-row distinct() collapses identical duplicates. A *conflicting*
  # duplicate survives it, so assert on the key as well: a pair differing
  # in any column (time, route) would otherwise double-weight a player in
  # every per-frame aggregate downstream.
  stopifnot(
    anyDuplicated(trk_week[c("game_id", "play_id", "nfl_id", "frame_id")]) == 0,
    !any(is.na(trk_week$side) & !trk_week$is_ball)
  )

  # Both distinct() and the key assertion above are per-week, so a play
  # appearing in two week files would pass both. Collect the keys and
  # check across weeks once the loop finishes.
  week_keys[[w]] <- distinct(trk_week, game_id, play_id)

  write_parquet(
    trk_week,
    path(processed, "tracking", sprintf("week_%02d.parquet", w))
  )

  rm(trk_week)
  gc()
}

# --- cross-week key check ---------------------------------------------

all_keys <- bind_rows(week_keys)
stopifnot(!any(duplicated(all_keys)))

# --- dedup report -----------------------------------------------------

dedup_summary <- dedup_log |>
  mutate(rows_removed = rows_in - rows_out) |>
  filter(rows_removed > 0)

if (nrow(dedup_summary)) {
  message(
    "Removed duplicate rows in ",
    nrow(dedup_summary),
    " week(s); ",
    sum(dedup_summary$rows_removed),
    " rows total:"
  )
  print(as.data.frame(dedup_summary))
} else {
  message("No duplicate rows found.")
}

write_parquet(dedup_log, path(processed, "dedup_log.parquet"))

message("Done. ", nrow(all_keys), " plays in the canonical tracking build.")
