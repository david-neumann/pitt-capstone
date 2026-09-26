# R/pbp.R -------------------------------------------------------------
# nflverse play-by-play bridge. Defines functions and constants only —
# no library() calls, no side effects, and no network access. The
# nflreadr::load_pbp() call lives in scripts/05_join_pbp.R so the
# download is an explicit build step with a pinned mirror, not a hidden
# dependency of sourcing this file.
#
# WHY THIS EXISTS. Four things the Kaggle download does not have: `cp`
# (the external benchmark), `air_yards` (BDB's plays.csv carries no
# throw depth at all), the pressure and spike flags, and game-state
# context. Everything else the play-by-play model stage needs is
# already in data/processed/plays.parquet — down, yards_to_go, quarter,
# offense_formation, type_dropback, defenders_in_the_box,
# number_of_pass_rushers. Check that table before adding a column here.
#
# JOIN KEYS. gameId -> old_game_id, playId -> play_id. Both nflverse
# columns arrive as the wrong type (character and double), and a type
# mismatch on a join key returns zero matches rather than an error, so
# the cast in standardize_pbp_keys() is load-bearing rather than
# cosmetic. Key-level match rate is also the weak check: matching real
# keys to the wrong plays passes it. outcome_agreement() is the strong
# one.
#
# `cp` IS NOT A CLEAN OUT-OF-SAMPLE RIVAL. nflfastR's completion
# probability model was trained on seasons including 2018, so its
# predictions here are partly in-sample, and it leans on human-charted
# air yards that no tracking-derived model has access to. It remains
# the field-standard reference. The claim it supports is "tracking
# geometry adds information beyond play-by-play", not "we beat cp".
# Recorded in notes/decisions.md.

source(here::here("R", "utils.R"))


# ---- column vocabulary ----------------------------------------------

#' Outcome-derived columns that must never reach a model frame
#'
#' Every one of these is a function of what happened after the throw.
#' `cpoe` is the sharpest case: it is 100 * (complete_pass - cp), so it
#' contains the response exactly. A leak of this kind is invisible in a
#' log-loss table — the model simply looks excellent — which is why the
#' exclusion is a named constant with an assertion behind it rather
#' than a careful select() in one script.
#'
#' Exact names only. Patterns are handled separately below, because
#' nflverse carries dozens of EPA and WP derivatives and enumerating
#' them by hand guarantees missing one.
#'
#' NOTE FOR scripts/08_build_model_frame.R: plays.parquet has its own
#' outcome columns (`epa`, `offense_play_result`, `play_result`) written
#' through verbatim by 02_build_canonical.R. This constant covers them
#' by name, but 08 has to actually run the assertion against the model
#' frame — 05 only guards its own output.
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

#' Regex patterns for the same thing, for families rather than columns
#'
#' Matched against names(df) case-insensitively. Deliberately broad:
#' a false positive here costs one line in an exception list, while a
#' false negative costs a result you have to retract.
#'
#' NOT included, and intentionally so: `ep`, `wp`, `vegas_wp`,
#' `spread_line`, and `total_line` are all pre-play quantities. They are
#' legitimate context features, not leaks.
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

#' The columns 05 carries forward, grouped by why
#'
#' Grouped as a named list rather than a flat vector so the script's
#' summary table and the Methods section can both name the reason each
#' block is here. Flatten with unlist(use.names = FALSE) at the
#' select().
#'
#' `week` collides with plays.parquet's own `week`, which is derived
#' from the BDB games table. It is carried anyway, as a redundancy
#' check — the two agree on every matched play — but 05 renames it to
#' `week_pbp` at the select, because two columns named `week` meaning
#' different things is exactly the ambiguity this file exists to remove.
#'
#' THE `validate` BLOCK IS NOT FEATURE MATERIAL. complete_pass,
#' interception, and sack are the response variable in another
#' encoding. They are written to pbp.parquet because outcome_agreement()
#' needs them and because a join check that cannot be re-run from the
#' persisted artifact is not reproducible. Dropping them is
#' scripts/08_build_model_frame.R's job, and 08 should assert their
#' absence from the model frame the way assert_no_leak_cols() asserts
#' here.
#'
#' `play_type` earns its place in that block: it is what distinguishes a
#' penalty-nullified snap ("no_play") from a real pass attempt, and the
#' nullified block is both large and selected on the outcome. See the
#' no-play note in scripts/05_join_pbp.R.
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

#' Rename and cast the nflverse keys to match the processed layer
#'
#' `old_game_id` is character ("2018090600") and `play_id` is double.
#' Both are cast to int32 via cast_keys() so the whole processed layer
#' shares one key type, the same discipline R/utils.R applies
#' everywhere else. The BDB gameId is the largest identifier in the
#' project and fits inside int32's 2147483647 ceiling.
#'
#' nflverse's own `game_id` is a different thing entirely — the
#' "2018_01_ATL_PHI" schedule key — so it is dropped before the rename
#' rather than carried alongside. Two columns named game_id meaning
#' different identifiers is the kind of thing that survives code review
#' and then produces an empty join.
#'
#' Errors rather than warns on a duplicated key or an unparseable
#' `old_game_id`: the join in 05 is onto the 19,239-row plays spine, so
#' a duplicated pbp key would fan those rows out silently, and
#' as.integer() on a non-numeric string returns NA with a warning
#' nobody reads.
#'
#' @param pbp Raw output of nflreadr::load_pbp().
#' @return The same table with int32 `game_id` and `play_id`.
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


#' Fail if any outcome-derived column survived the selection
#'
#' Called from scripts/05_join_pbp.R immediately before the write, so a
#' widened select() is a build-time error rather than an implausibly
#' good model in three weeks' time.
#'
#' The `validate` block of PBP_COLS is exempt by construction: those
#' columns are outcome encodings kept on purpose for the join check.
#' Everything else that looks like it was computed from the outcome is
#' rejected.
#'
#' @param df The assembled pbp table.
#' @param leak_cols Exact column names to reject.
#' @param leak_patterns Regexes to reject, matched case-insensitively.
#' @param allow Columns exempted despite matching. Defaults to the
#'   validate block.
#' @return `df`, invisibly, so the call can sit in a pipe.
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

#' Collapse the nflverse outcome flags to one label
#'
#' nflverse records the outcome as several indicators; BDB records it as
#' a single `pass_result` code. Comparing them needs one of the two
#' reshaped, and reshaping nflverse is the safer direction because the
#' collapse becomes explicit and testable here rather than implicit in a
#' cross-tabulation.
#'
#' PRECEDENCE, stated rather than left to case_when() ordering:
#'
#'   1. sack              — not a throw at all, so it outranks the rest
#'   2. intercepted       — before complete, since a tipped ball can in
#'                          principle set both
#'   3. complete
#'   4. incomplete        — a pass attempt that is none of the above
#'   5. no pass recorded  — nflverse logged no pass outcome at all
#'
#' THE LAST CLASS IS A LABEL, NOT AN NA, and that is deliberate. It is
#' the penalty-nullified block (see scripts/05_join_pbp.R §4), and an NA
#' there propagates through every comparison downstream: `NA == "x"` is
#' NA, filter() drops NA rows, and a sum over an NA-indexed subset
#' returns NA. Naming the class is what makes the block visible instead
#' of silently absent from the disagreement count.
#'
#' Verified empirically on the 2018 pull: `pass_attempt` is 1 on sacks,
#' so the (S, sack) cell is populated and no sack falls through to the
#' no-pass-recorded class. Recorded in notes/decisions.md.
#'
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


#' BDB pass_result codes mapped onto nflverse_outcome_class() labels
#'
#' `R` is the BDB scramble code. nflverse records a scramble as a rush
#' with no pass outcome, so "no pass recorded" is the *agreeing* value
#' there rather than a failure.
#'
#' `pass_result` is itself NA on a couple of plays. Those are not
#' checkable in either direction, and outcome_agreement() marks them
#' `checkable = FALSE` rather than guessing.
PASS_RESULT_EXPECTED <- c(
  C = "complete",
  I = "incomplete",
  IN = "intercepted",
  S = "sack",
  R = "no pass recorded"
)


#' Cross-tabulate BDB pass_result against the nflverse outcome
#'
#' THE DECISIVE JOIN CHECK. A high key match rate is consistent with
#' having matched real keys to the wrong plays; near-perfect block
#' diagonality here is not. Off-diagonal mass means the bridge is
#' wrong, and no amount of matched-row counting will say so.
#'
#' Returned long rather than pivoted so 05 can both print it and reduce
#' it to counts for an assertion. Pivot in the notebook, where it is
#' being read rather than tested.
#'
#' THREE KINDS OF NON-AGREEMENT, and conflating them is easy:
#'
#'   checkable = FALSE             BDB has no pass_result to compare
#'   nfl_outcome "no pbp row"      the join found nothing
#'   nfl_outcome "no pass
#'     recorded"                   matched, but nflverse logged no pass:
#'                                 the penalty-nullified block
#'
#' Only a `checkable` row whose nfl_outcome is a real pass outcome and
#' disagrees with `expected` indicts the join. No column returned here
#' is ever NA, so `filter(!agrees)` behaves.
#'
#' @param joined plays.parquet keys left-joined to the standardized pbp,
#'   carrying `pass_result`, `pbp_matched`, and the four nflverse
#'   outcome columns.
#' @return One row per (pass_result, nfl_outcome) with `n`, `expected`,
#'   `checkable`, and `agrees`.
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
      # checkable is FALSE wherever expected is NA, and FALSE & NA is
      # FALSE, so agrees never comes back NA.
      agrees = checkable & nfl_outcome == expected
    ) |>
    dplyr::arrange(pass_result, dplyr::desc(n))
}


#' Normalize a play description for comparison
#'
#' BDB `play_description` and nflverse `desc` come from the same league
#' feed, so they should agree up to formatting. Collapsing case and
#' whitespace and stripping punctuation turns the expected cosmetic
#' differences into matches and leaves substantive disagreement visible.
#'
#' Punctuation is replaced with a space rather than deleted, because
#' player names are abbreviated inconsistently between the two feeds
#' ("P.Mahomes" against "P. Mahomes") and deletion would fuse the
#' initial onto the surname in one feed but not the other, breaking
#' token comparison on every row.
normalize_desc <- function(x) {
  x |>
    toupper() |>
    gsub("[[:punct:]]", " ", x = _) |>
    gsub("\\s+", " ", x = _) |>
    trimws()
}


#' Token overlap between two normalized descriptions
#'
#' Jaccard index on whitespace-delimited tokens: the size of the
#' intersection over the size of the union.
#'
#' A PREFIX COMPARISON WAS TRIED FIRST AND FAILED. Comparing the first
#' 40 characters agreed on 5 plays of 19,238, which is not a formatting
#' difference — it is a systematic divergence in the head of the string,
#' and anchoring a comparison there makes a single extra leading token
#' look like total disagreement. Token overlap is invariant to
#' insertions, deletions, and reordering, so it measures whether the two
#' strings describe the same play rather than whether they were typeset
#' the same way. That is the question the join check is actually asking.
#'
#' Called on ~19k pairs; mapply handles that in about a second. Not
#' worth vectorizing further.
#'
#' @return Numeric vector in [0, 1]. NA where either side has no tokens.
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


#' Agreement between the two description columns
#'
#' The independent second opinion on the join. Two adjacent plays in the
#' same game often share an outcome class but never share a
#' description, so this is what would catch an off-by-one in `play_id`
#' that the outcome cross-tab could conceivably survive.
#'
#' Read `p10_similarity` first. If the tenth percentile of token overlap
#' is high, essentially every play matched its own description and the
#' join is confirmed from a second direction. `agree_exact` is reported
#' but is not the headline: it is brittle to a single differing token,
#' and its failing does not implicate the join.
#'
#' Returns a list rather than one tibble, because the summary and the
#' examples have different grains and the examples are for reading at
#' the console.
#'
#' @param joined Keys joined to pbp, carrying `play_description` and
#'   `desc`.
#' @param n_examples Lowest-similarity plays to return for inspection.
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
