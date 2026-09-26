# scripts/05_join_pbp.R ------------------------------------------------
# nflverse play-by-play -> processed. The only build script that touches
# the network. (R/viz.R also calls nflreadr, for team colours, on first
# use of team_fill_palette().)
#
# SCOPE: measured facts only, same rule as 03_build_play_index.R.
# Nothing here drops a play and nothing here is a modeling choice.
# `qb_spike` is a fact; `keep_not_spike` is a decision and belongs in
# R/sample_rules.R applied by scripts/08_build_model_frame.R, with a
# label in FLAG_LABELS so it appears in the question-level funnel.
#
# SPINE: the keys of data/processed/plays.parquet, all 19,239 plays,
# left join. NOT the analytic sample — a play that exits the sample
# later should still carry its pbp row, or re-scoping the question means
# rebuilding this file. Keys only, not the whole play table: 08 joins
# the two, and carrying a second copy of every play-level column here is
# how `cp.x` and `cp.y` happen.
#
# THE MIRROR STEP. nflreadr data is revised between releases, so the raw
# pull is written to data/interim/ before anything is done to it, for
# the same reason 01_raw_to_parquet.R exists: results produced in
# October have to reproduce in December. `nflverse_timestamp` is an
# attribute on the returned object and attributes do not survive a
# parquet round trip, so the sidecar metadata file is the only chance to
# keep it.
#
# Outputs, in data/interim/:
#   pbp_2018.parquet             verbatim nflreadr pull
#   pbp_2018_meta.parquet        pull provenance
# and in data/processed/:
#   pbp.parquet                  one row per play, on the plays keys
#   pbp_outcome_agreement.parquet  the join check, persisted
#
# Derived columns written by this script and by nothing else:
#   pbp_matched   the join found a pbp row for this play
#   has_cp        cp is present — see the note below, this is not MCAR
#   has_air_yards air_yards is present
#
# `cp` IS MISSING ON A NONRANDOM SUBSET, in two ways. It is missing
# wherever air_yards is, and it is missing on penalty-nullified plays
# (§4), which run heavily incomplete. Delta log loss across model stages
# is only comparable when every stage is scored on the same rows, so the
# headline comparison against the benchmark runs on has_cp == TRUE with
# full-sample numbers for the other stages reported alongside. has_cp
# travels with the data rather than being filtered on, the same pattern
# as defect_in_window in the sample layer.
#
# Run after 02_build_canonical.R. Independent of 03, 04, and 06.
# Requires network access on the first run only.

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
# The condition covers both files: a mirror without its provenance
# sidecar is re-pulled rather than silently accepted, because
# nflverse_timestamp cannot be recovered after the fact.

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
# standardize_pbp_keys() drops nflverse's own game_id, renames
# old_game_id, casts both keys to int32, and errors on an unparseable or
# duplicated key.

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

# Direction one is asserted rather than printed. A nonzero value means
# the key cast produced identifiers that do not exist in nflverse, which
# is a total join failure wearing the costume of a low match rate.
stopifnot(length(setdiff(bdb_games, nfl_games)) == 0)

# Direction two is expected to be nonzero, and its composition is the
# content: 11 postseason games plus the 3 week-1 games BDB omits (BDB
# ships 253 of the season's 256). A surplus game in any other week is a
# gap on the BDB side to record, not a postseason artifact.
pbp |>
  filter(game_id %in% setdiff(nfl_games, bdb_games)) |>
  distinct(game_id, week) |>
  count(week) |>
  print(n = Inf)

# BDB games per week, for the same reason: week 1 is 13 games, not 16,
# which is the denominator behind the week-1 coverage labels and the
# arrival-anchor prototyping sample.
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

# pbp_matched is a sentinel set before the join, not inferred from a
# content column afterwards: cp and air_yards are legitimately missing
# on matched rows, so is.na() on either would conflate "no pbp row" with
# "pbp row without a charted throw". Same pattern as target_tracked in
# 03_build_play_index.R.
pbp_out <- plays |>
  select(game_id, play_id) |>
  left_join(pbp_sel, by = c("game_id", "play_id")) |>
  mutate(
    pbp_matched = coalesce(pbp_matched, FALSE),
    has_cp = !is.na(cp),
    has_air_yards = !is.na(air_yards)
  )


# --- 4. validate the join ---------------------------------------------
# A high key match rate is consistent with having matched real keys to
# the WRONG plays, which would put one play's air yards beside another
# play's coverage geometry and still train, converge, and report
# plausible log loss. So this section verifies identity, not coverage,
# using two facts both sources record independently: the outcome and the
# description.
#
# `check` is scratch. It is never written; the artifact stays narrow and
# the checks join what they need.

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

# 4.2 week redundancy. Zero. A nonzero value means a BDB game_id matched
# a game in a different week, which is a bad cast that still found
# partners — the failure the game-set check cannot see.
stopifnot(sum(check$week != check$week_pbp, na.rm = TRUE) == 0)

# 4.3 the decisive check
oa <- outcome_agreement(check)
print(as.data.frame(oa))

# Three kinds of non-agreement, separated. Only the first indicts the
# join; see the header of outcome_agreement() in R/pbp.R.
oa_bad <- filter(oa, checkable, nfl_outcome != "no pass recorded", !agrees)
oa_nullified <- filter(
  oa,
  checkable,
  nfl_outcome == "no pass recorded",
  !agrees
)

message("off-diagonal plays (real outcome disagreement): ", sum(oa_bad$n))
message("matched plays with no nflverse pass outcome: ", sum(oa_nullified$n))

# 4.4 what the no-pass-recorded block is. plays.parquet already carries
# the BDB penalty columns, so this needs nothing from nflverse.
check |>
  filter(pbp_matched, play_type == "no_play") |>
  count(has_penalty = !is.na(penalty_codes), is_defensive_pi, pass_result) |>
  arrange(desc(n)) |>
  print(n = 20)

# The outcome skew is the finding, not the count. Defensive pass
# interference nullifies incompletions, so this block runs far more
# incomplete than the sample it is being removed from — the same shape
# of problem as the missing-LOS block in 01_eda.qmd 2.6, and it has to
# be recorded the same way, with counts, in notes/decisions.md.
check |>
  filter(pbp_matched, pass_result %in% c("C", "I", "IN")) |>
  mutate(nullified = play_type == "no_play") |>
  count(nullified, pass_result) |>
  group_by(nullified) |>
  mutate(share = n / sum(n)) |>
  ungroup() |>
  print(n = 20)

# And whether cp survives on them, which is what decides the benchmark's
# scoring population.
check |>
  count(nullified = play_type == "no_play", has_cp) |>
  print(n = 20)

# 4.5 the independent second opinion. Read p10_similarity, not
# agree_exact.
da <- desc_agreement(check)
print(as.data.frame(da$summary))
print(as.data.frame(da$examples))

# 4.6 air_yards plausibility, and the boundary that matters for 08.
# air_yards == 0 is the ambiguous case for a beyond-the-LOS filter, so
# count it explicitly rather than reading it off a quantile.
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

# Pinned after inspection, not before: as of the pull recorded in
# pbp_2018_meta.parquet, every matched play with a real nflverse pass
# outcome agrees with BDB's pass_result. The nullified block is counted
# separately in 4.3 and is not a disagreement about what happened.
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
