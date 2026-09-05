library(arrow)
library(dplyr)
library(fs)
library(here)

source(here("R", "constants.R"))
source(here("R", "standardize.R"))
source(here("R", "viz.R"))

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

# --- games ---
games <- read_parquet(path(interim, "games.parquet"))
require_cols(games, c("gameId", "homeTeamAbbr", "visitorTeamAbbr"), "games")

game_teams <- games |>
  mutate(
    game_id = gameId,
    home_team = homeTeamAbbr,
    away_team = visitorTeamAbbr
  )

write_parquet(game_teams, path(processed, "games.parquet"))

# --- one play_direction per play ---
trk_raw <- open_dataset(path(interim, "tracking"))

play_dir <- trk_raw |>
  select(gameId, playId, playDirection) |>
  distinct() |>
  collect() |>
  rename(
    game_id = gameId,
    play_id = playId,
    play_direction = playDirection
  )

# A play must have exactly one play direction
stopifnot(!any(duplicated(play_dir[c("game_id", "play_id")])))

# --- plays ---
plays <- read_parquet(path(interim, "plays.parquet")) |>
  rename_with(to_snake) |>
  left_join(play_dir, by = c("game_id", "play_id")) |>
  left_join(game_teams, by = "game_id") |>
  mutate(
    defense_team = if_else(possession_team == home_team, away_team, home_team),
    los_x = standardize_los(absolute_yardline_number, play_direction)
  )

stopifnot(!anyNA(plays$play_direction))
write_parquet(plays, path(processed, "plays.parquet"))

# --- players ---
read_parquet(path(interim, "players.parquet")) |>
  rename_with(to_snake) |>
  write_parquet(path(processed, "players.parquet"))

# --- tracking, one week at a time ---
side_lookup <- plays |>
  select(game_id, play_id, possession_team, home_team, away_team)

for (w in 1:17) {
  message("Canonicalizing week ", w)

  trk_raw |>
    filter(week == w) |>
    collect() |>
    rename_with(to_snake) |>
    left_join(side_lookup, by = c("game_id", "play_id")) |>
    mutate(
      is_ball = team == "football",
      team_abbr = case_when(
        team == "home" ~ home_team,
        team == "away" ~ away_team,
        TRUE ~ NA_character_
      ),
      side = case_when(
        is_ball ~ "ball",
        team_abbr == possession_team ~ "offense",
        TRUE ~ "defense"
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
    ) |>
    write_parquet(path(processed, "tracking", sprintf("week_%02d.parquet", w)))

  gc()
}

message("Done.")
