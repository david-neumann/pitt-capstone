# R/pbp.R -------------------------------------------------------------
# Bridge between the BDB tables and nflverse play-by-play: key
# standardization, column vocabulary, leak assertion, and join
# validation. No network access; the download is in
# scripts/05_join_pbp.R.
#
# The join supplies `cp` (the external benchmark), `air_yards`,
# pressure and spike flags, and game context. Other play-level columns
# come from data/processed/plays.parquet.
#
# `cp` is not an out-of-sample competitor: nflfastR's model was trained
# on seasons including 2018 and uses charted air yards. See
# notes/decisions.md §8.6.

source(here::here("R", "utils.R"))


# ---- column vocabulary ----------------------------------------------

#' Outcome-derived columns that must not reach a model frame
#'
#' Each is a function of what happened after the throw (`cpoe`, for
#' example, is 100 * (complete_pass - cp)). Includes the BDB columns
#' `epa`, `play_result`, and `offense_play_result` from plays.parquet.
#' Checked by assert_no_leak_cols().
PBP_LEAK_COLS <- c(
  "cpoe",
  "epa",
  "wpa",
  "yards_gained",
  "yards_after_catch",
  "air_yards_gained",
  "offense_play_result",
  "play_result",
  "success",
  "safety",
  "fumble",
  "fumble_lost",
  "return_yards",
  "penalty_yards"
)

#' Regex patterns for families of outcome-derived columns
#'
#' Matched case-insensitively. Pre-play quantities (`ep`, `wp`,
#' `vegas_wp`, `spread_line`, `total_line`) are not leaks and are not
#' matched.
PBP_LEAK_PATTERNS <- c(
  "_epa$",
  "^epa_",
  "_wpa$",
  "wp_post",
  "^xyac",
  "^xpass",
  "first_down",
  "touchdown",
  "^comp_",
  "^yac_"
)

#' Columns carried forward from nflverse, grouped by purpose
#'
#' Flatten with `unlist(use.names = FALSE)`. `week` is renamed to
#' `week_pbp` by scripts/05_join_pbp.R and used only as a join check.
#'
#' The `validate` block encodes the outcome and is kept only for join
#' validation; it must be dropped from any model frame.
PBP_COLS <- list(
  keys = c("game_id", "play_id", "week"),
  benchmark = c("cp"),
  throw = c("air_yards", "pass_location", "pass_length"),
  pressure = c("qb_hit", "qb_spike", "qb_scramble", "qb_dropback"),
  context = c(
    "score_differential",
    "game_seconds_remaining",
    "half_seconds_remaining",
    "shotgun",
    "no_huddle",
    "posteam_type"
  ),
  validate = c(
    "desc",
    "play_type",
    "complete_pass",
    "interception",
    "sack",
    "pass_attempt"
  )
)


# ---- keys ------------------------------------------------------------

#' Rename and cast nflverse keys to match the processed layer
#'
#' Drops nflverse's `game_id` (a schedule key such as "2018_01_ATL_PHI"),
#' renames `old_game_id` to `game_id`, and casts both keys to int32 with
#' cast_keys(). Errors on an unparseable `old_game_id` or a duplicated
#' key, either of which would corrupt a join silently.
#'
#' @param pbp Output of nflreadr::load_pbp().
#' @return `pbp` with int32 `game_id` and `play_id`.
standardize_pbp_keys <- function(pbp) {
  missing <- setdiff(c("old_game_id", "play_id"), names(pbp))
  if (length(missing)) {
    stop(
      "pbp is missing expected key columns: ",
      paste0(missing, collapse = ", "),
      ". Check the nflreadr schema.",
      call. = FALSE
    )
  }

  out <- pbp |>
    dplyr::select(-dplyr::any_of("game_id")) |>
    dplyr::rename(game_id = old_game_id) |>
    cast_keys()

  n_unparsed <- sum(is.na(out$game_id) & !is.na(pbp$old_game_id))
  if (n_unparsed) {
    stop(
      n_unparsed,
      " old_game_id values did not parse as integers. The cast to int32 ",
      "would silently drop them from every join.",
      call. = FALSE
    )
  }

  dup <- sum(duplicated(out[c("game_id", "play_id")]))
  if (dup) {
    stop(
      dup,
      " duplicated (game_id, play_id) keys in the pbp table. A left join ",
      "onto the plays spine would fan those rows out.",
      call. = FALSE
    )
  }

  out
}


#' Fail if any outcome-derived column is present
#'
#' @param df A table about to be written or modeled.
#' @param leak_cols Exact column names to reject.
#' @param leak_patterns Regexes to reject, matched case-insensitively.
#' @param allow Columns exempted despite matching. Defaults to the
#'   `validate` block of PBP_COLS; pass `character(0)` for a model frame.
#' @return `df`, invisibly.
assert_no_leak_cols <- function(
  df,
  leak_cols = PBP_LEAK_COLS,
  leak_patterns = PBP_LEAK_PATTERNS,
  allow = PBP_COLS$validate
) {
  nms <- names(df)

  hit_exact <- intersect(nms, leak_cols)
  hit_pattern <- nms[
    Reduce(
      `|`,
      lapply(leak_patterns, \(p) grepl(p, nms, ignore.case = TRUE)),
      init = rep(FALSE, length(nms))
    )
  ]

  offenders <- setdiff(union(hit_exact, hit_pattern), allow)

  if (length(offenders)) {
    stop(
      "Outcome-derived columns present: ",
      paste0(offenders, collapse = ", "),
      ". These are functions of what happened after the throw and would ",
      "leak the response into any model fit on this table. Drop them in ",
      "scripts/05_join_pbp.R, or add to `allow` with a written reason.",
      call. = FALSE
    )
  }

  invisible(df)
}


# ---- join validation -------------------------------------------------

#' Collapse the nflverse outcome indicators to one label
#'
#' Precedence: sack, intercepted, complete, incomplete (any other pass
#' attempt), then "no pass recorded". The last is a label rather than NA
#' so that it is counted, not silently dropped, in comparisons.
#'
#' @param complete_pass,interception,sack,pass_attempt nflverse 0/1
#'   indicators.
#' @return Character vector, never NA.
nflverse_outcome_class <- function(
  complete_pass,
  interception,
  sack,
  pass_attempt
) {
  dplyr::case_when(
    dplyr::coalesce(sack, 0) == 1 ~ "sack",
    dplyr::coalesce(interception, 0) == 1 ~ "intercepted",
    dplyr::coalesce(complete_pass, 0) == 1 ~ "complete",
    dplyr::coalesce(pass_attempt, 0) == 1 ~ "incomplete",
    .default = "no pass recorded"
  )
}


#' Expected nflverse_outcome_class() label for each BDB pass_result code
#'
#' nflverse records a scramble (`R`) as a run, so "no pass recorded" is
#' the agreeing value.
PASS_RESULT_EXPECTED <- c(
  C = "complete",
  I = "incomplete",
  IN = "intercepted",
  S = "sack",
  R = "no pass recorded"
)


#' Cross-tabulate BDB pass_result against the nflverse outcome
#'
#' Verifies that matched keys refer to the same plays, which a match rate
#' cannot show. Three kinds of non-agreement are kept distinct:
#'
#'   checkable = FALSE               no BDB pass_result to compare, or no
#'                                   pbp row
#'   nfl_outcome "no pbp row"        the join found nothing
#'   nfl_outcome "no pass recorded"  matched, but nflverse logged no pass
#'                                   (penalty-nullified plays)
#'
#' Only a checkable row with a real nflverse outcome that disagrees with
#' `expected` indicates a join error.
#'
#' @param joined plays.parquet keys left-joined to the standardized pbp,
#'   with `pass_result`, `pbp_matched`, and the four nflverse outcome
#'   columns.
#' @return One row per (pass_result, nfl_outcome) with `n`, `expected`,
#'   `checkable`, and `agrees`. `agrees` is never NA.
outcome_agreement <- function(joined) {
  joined |>
    dplyr::mutate(
      nfl_outcome = dplyr::if_else(
        dplyr::coalesce(pbp_matched, FALSE),
        nflverse_outcome_class(
          complete_pass,
          interception,
          sack,
          pass_attempt
        ),
        "no pbp row"
      ),
      expected = unname(PASS_RESULT_EXPECTED[pass_result]),
      checkable = !is.na(expected) & nfl_outcome != "no pbp row"
    ) |>
    dplyr::count(pass_result, nfl_outcome, expected, checkable) |>
    dplyr::mutate(
      # checkable is FALSE wherever expected is NA, so this is never NA.
      agrees = checkable & nfl_outcome == expected
    ) |>
    dplyr::arrange(pass_result, dplyr::desc(n))
}


#' Normalize a play description for token comparison
#'
#' Upper-cases, replaces punctuation with spaces, and collapses
#' whitespace. Replacing rather than deleting punctuation keeps "P.Mahomes"
#' and "P. Mahomes" as the same tokens.
normalize_desc <- function(x) {
  x |>
    toupper() |>
    gsub("[[:punct:]]", " ", x = _) |>
    gsub("\\s+", " ", x = _) |>
    trimws()
}


#' Jaccard similarity of whitespace-delimited tokens
#'
#' Insensitive to inserted, deleted, or reordered tokens, which matters
#' because nflverse descriptions prefix jersey numbers and use different
#' team abbreviations from BDB.
#'
#' @param a,b Normalized descriptions.
#' @return Numeric vector in [0, 1]; NA where either side has no tokens.
desc_similarity <- function(a, b) {
  ta <- strsplit(a, " ", fixed = TRUE)
  tb <- strsplit(b, " ", fixed = TRUE)

  mapply(
    function(u, v) {
      if (!length(u) || !length(v)) {
        return(NA_real_)
      }
      length(intersect(u, v)) / length(union(u, v))
    },
    ta,
    tb,
    USE.NAMES = FALSE
  )
}


#' Agreement between BDB and nflverse play descriptions
#'
#' An independent check on the join: adjacent plays can share an outcome
#' but not a description, so this catches off-by-one key errors that
#' outcome_agreement() might not. `p10_similarity` is the headline; exact
#' agreement is near zero by construction (see desc_similarity()).
#'
#' @param joined Keys joined to pbp, with `play_description` and `desc`.
#' @param n_examples Number of lowest-similarity plays to return.
#' @return list(summary = one-row tibble, examples = tibble).
desc_agreement <- function(joined, n_examples = 10) {
  cmp <- joined |>
    dplyr::filter(!is.na(desc), !is.na(play_description)) |>
    dplyr::mutate(
      bdb = normalize_desc(play_description),
      nfl = normalize_desc(desc),
      agree_exact = bdb == nfl,
      similarity = desc_similarity(bdb, nfl)
    )

  summary <- tibble::tibble(
    plays_compared = nrow(cmp),
    agree_exact = mean(cmp$agree_exact),
    p10_similarity = unname(
      stats::quantile(cmp$similarity, 0.10, na.rm = TRUE)
    ),
    p50_similarity = stats::median(cmp$similarity, na.rm = TRUE),
    pct_above_0.8 = mean(cmp$similarity > 0.8, na.rm = TRUE)
  )

  examples <- cmp |>
    dplyr::slice_min(similarity, n = n_examples, with_ties = FALSE) |>
    dplyr::select(
      dplyr::any_of(c("game_id", "play_id", "pass_result")),
      similarity,
      play_description,
      desc
    )

  list(summary = summary, examples = examples)
}
