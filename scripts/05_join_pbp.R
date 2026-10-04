# scripts/05_join_pbp.R ------------------------------------------------
# nflverse play-by-play -> processed. Downloads on the first run only.
#
# Records measured facts only and drops no plays; flags such as
# `qb_spike` are applied as filters later, via R/sample_rules.R.
#
# The output is left-joined onto the keys of every play in
# data/processed/plays.parquet (not just the analytic sample) and carries
# no other play-level columns.
#
# nflverse data is revised between releases, so the raw pull is mirrored
# to data/interim/ before use, with its release timestamp saved in a
# sidecar file (object attributes do not survive Parquet).
#
# Outputs, in data/interim/:
#   pbp_2018.parquet             verbatim nflreadr pull
#   pbp_2018_meta.parquet        pull provenance
# and in data/processed/:
#   pbp.parquet                  one row per play, on the plays keys
#   pbp_outcome_agreement.parquet  the join check, persisted
#
# Derived columns:
#   pbp_matched    the join found a pbp row for this play
#   has_cp         cp is present
#   has_air_yards  air_yards is present
#
# `cp` is present only where `air_yards` is, and is also missing on some
# plays that have `air_yards`. Penalty-nullified plays (play_type
# "no_play"), which are mostly incomplete, have neither. has_cp is
# therefore not missing at random; it is carried as a flag, not filtered
# on.
#
# Run after 02_build_canonical.R. Independent of 03 and 04.

library(arrow)
library(dplyr)
library(tibble)
library(fs)
library(here)

source(here("R", "utils.R"))
source(here("R", "pbp.R"))

processed <- here("data", "processed")
interim_dir <- here("data", "interim")

mirror <- path(interim_dir, "pbp_2018.parquet")
mirror_meta <- path(interim_dir, "pbp_2018_meta.parquet")

plays <- read_parquet(path(processed, "plays.parquet"))


# --- 1. mirror the pull -----------------------------------------------
# Re-pull if either file is missing, since the timestamp cannot be
# recovered later.

if (!file_exists(mirror) || !file_exists(mirror_meta)) {
  message("Pulling nflverse play-by-play for 2018")

  pbp_raw <- nflreadr::load_pbp(2018)

  write_parquet(pbp_raw, mirror)
  write_parquet(
    tibble(
      pulled_at = Sys.time(),
      nflreadr_version = as.character(packageVersion("nflreadr")),
      nflverse_timestamp = as.character(
        attr(pbp_raw, "nflverse_timestamp") %||% NA_character_
      ),
      n_rows = nrow(pbp_raw),
      n_cols = ncol(pbp_raw)
    ),
    mirror_meta
  )

  rm(pbp_raw)
}

pbp_2018 <- read_parquet(mirror)
pbp_meta <- read_parquet(mirror_meta)

print(as.data.frame(pbp_meta))


# --- 2. keys ----------------------------------------------------------

pbp <- standardize_pbp_keys(pbp_2018)

bdb_games <- sort(unique(plays$game_id))
nfl_games <- sort(unique(pbp$game_id))

print(tibble(
  direction = c(
    "BDB games absent from nflverse",
    "nflverse games absent from BDB"
  ),
  n = c(
    length(setdiff(bdb_games, nfl_games)),
    length(setdiff(nfl_games, bdb_games))
  )
))

# Every BDB game must exist in nflverse; otherwise the key cast is wrong.
stopifnot(length(setdiff(bdb_games, nfl_games)) == 0)

# Expected: 11 postseason games plus 3 week-1 games absent from BDB
# (253 of 256 regular-season games).
pbp |>
  filter(game_id %in% setdiff(nfl_games, bdb_games)) |>
  distinct(game_id, week) |>
  count(week) |>
  print(n = Inf)

# BDB games per week (week 1 has 13).
plays |>
  group_by(week) |>
  summarize(games = n_distinct(game_id), plays = n(), .groups = "drop") |>
  print(n = Inf)


# --- 3. join and select -----------------------------------------------

require_cols(pbp, unlist(PBP_COLS, use.names = FALSE), "nflverse pbp")

pbp_sel <- pbp |>
  select(all_of(unlist(PBP_COLS, use.names = FALSE))) |>
  rename(week_pbp = week) |>
  mutate(pbp_matched = TRUE)

# pbp_matched is set before the join because cp and air_yards can be
# missing on matched rows.
pbp_out <- plays |>
  select(game_id, play_id) |>
  left_join(pbp_sel, by = c("game_id", "play_id")) |>
  mutate(
    pbp_matched = coalesce(pbp_matched, FALSE),
    has_cp = !is.na(cp),
    has_air_yards = !is.na(air_yards)
  )


# --- 4. validate the join ---------------------------------------------
# A match rate cannot show that keys matched the right plays, so the
# outcome and the description are compared between sources. `check` is
# not written.

check <- pbp_out |>
  left_join(
    plays |>
      select(
        game_id,
        play_id,
        week,
        quarter,
        pass_result,
        play_description,
        penalty_codes,
        is_defensive_pi
      ),
    by = c("game_id", "play_id")
  )

# 4.1 match rate and the composition of the residual
message("match rate: ", sprintf("%.6f", mean(check$pbp_matched)))

check |>
  filter(!pbp_matched) |>
  count(pass_result, quarter, sort = TRUE) |>
  print(n = 20)

# 4.2 week agreement between sources.
stopifnot(sum(check$week != check$week_pbp, na.rm = TRUE) == 0)

# 4.3 outcome agreement
oa <- outcome_agreement(check)
print(as.data.frame(oa))

# Only oa_bad indicates a join error; see outcome_agreement().
oa_bad <- filter(oa, checkable, nfl_outcome != "no pass recorded", !agrees)
oa_nullified <- filter(
  oa,
  checkable,
  nfl_outcome == "no pass recorded",
  !agrees
)

message("off-diagonal plays (real outcome disagreement): ", sum(oa_bad$n))
message("matched plays with no nflverse pass outcome: ", sum(oa_nullified$n))

# 4.4 composition of the no-pass-recorded block, by BDB penalty columns.
check |>
  filter(pbp_matched, play_type == "no_play") |>
  count(has_penalty = !is.na(penalty_codes), is_defensive_pi, pass_result) |>
  arrange(desc(n)) |>
  print(n = 20)

# Outcome composition of nullified vs other throws (notes/decisions.md
# §8.3).
check |>
  filter(pbp_matched, pass_result %in% c("C", "I", "IN")) |>
  mutate(nullified = play_type == "no_play") |>
  count(nullified, pass_result) |>
  group_by(nullified) |>
  mutate(share = n / sum(n)) |>
  ungroup() |>
  print(n = 20)

# cp availability on nullified plays.
check |>
  count(nullified = play_type == "no_play", has_cp) |>
  print(n = 20)

# 4.5 description agreement; p10_similarity is the headline.
da <- desc_agreement(check)
print(as.data.frame(da$summary))
print(as.data.frame(da$examples))

# 4.6 air_yards distribution, with exact counts at and below zero.
check |>
  filter(has_air_yards) |>
  summarize(
    p01 = quantile(air_yards, 0.01),
    p50 = quantile(air_yards, 0.50),
    p99 = quantile(air_yards, 0.99),
    min = min(air_yards),
    max = max(air_yards),
    n_negative = sum(air_yards < 0),
    n_zero = sum(air_yards == 0),
    pct_at_or_below_zero = mean(air_yards <= 0)
  ) |>
  as.data.frame() |>
  print()


# --- 5. assertions and write ------------------------------------------

stopifnot(
  nrow(pbp_out) == nrow(plays),
  !any(duplicated(pbp_out[c("game_id", "play_id")])),
  !anyNA(pbp_out$pbp_matched),
  !anyNA(pbp_out$has_cp),
  !anyNA(pbp_out$has_air_yards)
)

# Zero as of the mirrored pull. Nullified plays are counted separately.
stopifnot(sum(oa_bad$n) == 0)

assert_no_leak_cols(pbp_out)

write_parquet(pbp_out, path(processed, "pbp.parquet"))
write_parquet(oa, path(processed, "pbp_outcome_agreement.parquet"))


# --- 6. summary -------------------------------------------------------

print(
  tibble(
    quantity = c(
      "plays on the spine",
      "plays matched to pbp",
      "plays with cp",
      "plays with air_yards",
      "plays nullified by penalty (no_play)",
      "plays flagged qb_spike",
      "plays flagged qb_hit",
      "plays flagged qb_scramble"
    ),
    n = c(
      nrow(pbp_out),
      sum(pbp_out$pbp_matched),
      sum(pbp_out$has_cp),
      sum(pbp_out$has_air_yards),
      sum(coalesce(pbp_out$play_type == "no_play", FALSE)),
      sum(coalesce(pbp_out$qb_spike == 1, FALSE)),
      sum(coalesce(pbp_out$qb_hit == 1, FALSE)),
      sum(coalesce(pbp_out$qb_scramble == 1, FALSE))
    )
  ) |>
    mutate(pct_of_spine = n / nrow(pbp_out))
)

message(
  "Done. ",
  sum(pbp_out$pbp_matched),
  " of ",
  nrow(pbp_out),
  " plays matched; ",
  sum(pbp_out$has_cp),
  " carry the cp benchmark."
)
