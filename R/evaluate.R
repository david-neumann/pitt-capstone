# R/evaluate.R -----------------------------------------------------
# Cross-validation harness and scoring for the completion model.
# Defines functions only — no library() calls, no side effects.
#
# PRECONDITION: every function here assumes it is handed the final
# scoring population, with no missing values in any variable used by
# any model spec. Folds built before that filter would differ from
# folds built after it, and a delta log loss across different row
# sets is not a delta.
#
# Functions appear in the order the workflow calls them:
#
#   prepare_model_frame()   response and derived predictors
#   MODEL_SPECS             the nested stages
#   model_vars()            what the specs require
#   assert_complete()       tripwire on the population
#   incomplete_report()     what a complete-case restriction costs
#   make_folds()            leave-one-week-out resampling
#   fit_one() / fit_fold()  one fit
#   cv_predict()            out-of-fold predictions, one spec
#   cv_predict_all()        out-of-fold predictions, every spec
#   fit_full()              one fit on everything, for interpretation
#
# REQUIRES mgcv to be ATTACHED, not merely installed, before any fit.
# The spec formulas are written with bare s(), and the formula's
# environment has to resolve it. library(mgcv) belongs in the notebook.

# ---- model frame -------------------------------------------------

#' Response variable and predictor preparation
#'
#' Kept as a function rather than done in the notebook so every stage
#' and the benchmark see identical columns. `complete` is 1 for C and 0
#' for I and IN: an interception is an incompletion, which is how
#' nflverse `cp` is defined and is what makes the benchmark comparable.
#'
#' RARE FACTOR LEVELS are lumped before folding. As of the 2018 build
#' this affects nothing — `pass_location` has three well-populated
#' levels — so the mechanism is a guard rather than an active
#' transformation. It is retained because the failure it prevents is
#' severe and silent: a level confined to one week is absent from that
#' fold's training set, and predict() errors on an unseen level rather
#' than returning NA. `offense_formation` was the reason it was written
#' (WILDCAT had 31 plays, 17 of them in week 14) and is no longer in
#' any spec; see the MODEL_SPECS notes for why it was dropped.
#'
#' NA MUST SURVIVE LUMPING AS NA. Mapping it to "other" would convert
#' missingness into a category and silently defeat assert_complete(),
#' which is the one thing guaranteeing every stage scores the same rows.
#'
#' COUNT PREDICTORS are clamped to their supported range.
#' `number_of_pass_rushers` has tails holding one or two plays (9
#' occurs once; 0 occurs 16 times), and a single observation at the end
#' of a spline determines that end of the spline. Worse, on the fold
#' holding out the week containing that observation, predicting it is
#' extrapolation beyond the training range, where a spline returns a
#' number with no data behind it. Clamping to [2, 7] loses no rows: 117
#' plays (0.7%) move. Zero pass rushers on a pass play is a charting
#' artifact rather than a football event.
prepare_model_frame <- function(
  df,
  min_level_n = 100,
  rush_range = c(2, 7)
) {
  stopifnot(
    all(df$pass_result %in% c("C", "I", "IN")),
    !anyNA(df$pass_result)
  )

  lump <- function(x) {
    x <- as.character(x)
    keep <- names(which(table(x) >= min_level_n))
    factor(dplyr::case_when(
      is.na(x) ~ NA_character_,
      x %in% keep ~ x,
      .default = "other"
    ))
  }

  clamp <- function(x, lo, hi) pmin(pmax(x, lo), hi)

  df |>
    dplyr::mutate(
      complete = as.integer(pass_result == "C"),
      down = factor(down),
      pass_location = lump(pass_location),
      number_of_pass_rushers = clamp(
        number_of_pass_rushers,
        rush_range[1],
        rush_range[2]
      ),

      # Distance to sticks. Additive smooths in air_yards and
      # yards_to_go cannot represent their difference, which is an
      # interaction: a 3-yard throw on 3rd-and-2 and on 3rd-and-15 are
      # different plays. `yards_to_go` is therefore dropped as a main
      # effect, because dist = air - ytg makes all three exactly
      # dependent in the unpenalized null space — the same trap as
      # l_par / l_perp / d in R/geometry.R. {air_yards, dist_to_sticks}
      # spans the same linear space as {air_yards, yards_to_go}, so
      # nothing is lost but a nonlinear-in-yards_to_go term.
      dist_to_sticks = air_yards - yards_to_go,

      # A penalized spline smooths over a point mass; a tree can split
      # on it. So this indicator is MORE useful here than in nflverse's
      # model, where it is described as a relic of pre-tree versions.
      # 1,093 plays sit at exactly 0 and complete at a markedly lower
      # rate than their neighbourhood. Provisional: the beyond-the-LOS
      # filter in 08 removes these plays entirely.
      air_yards_zero = as.integer(air_yards == 0),

      home = as.integer(posteam_type == "home")
    )
}


# ---- the stages --------------------------------------------------

#' The nested model stages, declared once
#'
#' A named list so the notebook loops over it and adding a stage is one
#' entry rather than a new code path. Each entry carries its engine,
#' because the intercept model does not need mgcv and using glm() there
#' makes the floor unambiguous.
#'
#' THE NESTING IS THE ARGUMENT. Stage 2 already knows the situation and
#' the difficulty of the throw, including its depth. Stages 3 and 4
#' therefore have to earn their improvement on coverage information
#' alone. Putting depth in stage 3 instead would credit "how far the
#' ball went" to coverage geometry, which is the obvious objection and
#' the easiest one to preempt.
#'
#' A COROLLARY WORTH HOLDING ONTO: every variable removed from stage 2
#' makes the headline delta LARGER and LESS defensible, because the
#' improvement attributed to coverage geometry may be information the
#' baseline was simply never given. Cut terms by argument — this is
#' scheme rather than difficulty, this charting is unreliable — and not
#' by in-sample p-value, which is the move that makes a nested
#' comparison look tuned.
MODEL_SPECS <- list(
  `1. intercept` = list(
    engine = "glm",
    formula = complete ~ 1
  ),

  # STAGE 2 tracks nflverse `cp`'s feature set wherever the BDB data
  # supports it, deliberately, so the benchmark comparison is close to
  # a fair fight: yard line, down, distance to sticks, air yards, the
  # zero-air-yards indicator, pass location, home field, and qb_hit.
  #
  # Departures from `cp`, each argued:
  #
  #   - THREE pass locations, not middle / not-middle. Right and left
  #     differ from each other by roughly 8 standard errors (+0.178 and
  #     -0.140 against a left reference, SE ~0.04), so collapsing them
  #     discards real information.
  #   - `number_of_pass_rushers` added, at chi-sq 39.7. A *defensive*
  #     control, which forecloses the objection that the stage 3 and 4
  #     tracking features are merely recapturing how many defenders
  #     rushed versus dropped into coverage.
  #   - `air_yards_zero` is LOAD-BEARING here, at -0.87 on the logit
  #     scale against an intercept of 1.00 — roughly halving the odds
  #     of completion. nflverse calls it a relic of pre-tree models,
  #     and for a tree it is: a tree can split at exactly 0. A
  #     penalized spline smooths straight over a point mass. Freeing it
  #     raised s(air_yards) edf from 4.37 to 7.67 and improved deviance
  #     explained on a strictly smaller model.
  #   - `roof` and era omitted. Era is meaningless on a single season,
  #     and roof would require widening PBP_COLS and re-running 05.
  #
  # Tested and dropped:
  #
  #   - `offense_formation`. It describes scheme rather than throw
  #     difficulty, and it was aliased with `shotgun` (an EMPTY-
  #     backfield snap is essentially always from shotgun), which
  #     inflated the standard error on the intercept and on every
  #     formation level from ~0.04 to ~0.35. Dropping it made `shotgun`
  #     estimable, at which point the coefficient is NEGATIVE (-0.171,
  #     SE 0.047): conditional on depth, shotgun passes complete less
  #     often. The raw shotgun advantage in the conventional wisdom is
  #     confounded by shotgun throws being systematically shorter.
  #   - `defenders_in_the_box` and `score_differential`, both at
  #     edf ~1.00 with p > 0.05, and both droppable by argument as well
  #     as by fit: the box count is vendor-charted with implausible
  #     tail values (1 and 2 defenders), and the blowout mechanism
  #     behind score_differential is plausible a priori but absent from
  #     the data.
  #
  # RETAINED DESPITE BEING NULL: `s(dist_to_sticks)` comes back at
  # edf 1.01, p = 0.10. It stays, per the corollary above, and because
  # it spans the yards_to_go direction — dropping it would remove that
  # variable from the model entirely.
  #
  # `air_yards` is PROVISIONAL, but not for reasons of missingness: it
  # is absent on 3 plays of 17,077 in the throw population (1 complete,
  # 2 incomplete, checked and immaterial). It is provisional because it
  # is human-charted rather than measured. Once
  # scripts/06_build_throw_frame.R exists, the tracking-derived throw
  # distance replaces it as the depth control and `air_yards` becomes a
  # robustness refit. Keeping a charted variable as the stage-2 control
  # in the meantime also keeps stage 2 closer to what `cp` itself sees.
  #
  # Smooths: s() on the continuous predictors; k = 5 on
  # number_of_pass_rushers, whose clamped support is 6 distinct values,
  # so the default basis would be larger than the data can identify.
  # REML rather than the default GCV, set at fit time in fit_one().
  `2. play-by-play` = list(
    engine = "gam",
    formula = complete ~
      s(air_yards) +
      s(dist_to_sticks) +
      s(los_x) +
      s(number_of_pass_rushers, k = 5) +
      air_yards_zero +
      down +
      pass_location +
      shotgun +
      home +
      qb_hit
  )

  # `3. + separation` and `4. + geometry` are added once
  # scripts/07_build_features.R exists. Stage 3 adds distance to the
  # nearest defender and its analytic rate of change; stage 4 adds
  # leverage, the corridor features, and time-to-arrival. Not stubbed
  # here, because a formula referencing columns that do not exist is
  # a landmine rather than a placeholder.
)


# ---- the scoring population --------------------------------------

#' Every variable referenced by any model spec
#'
#' all.vars() on a formula returns variable names and drops function
#' names and literals, so `s(air_yards, k = 5)` yields "air_yards" and
#' not "s" or "k". That is what makes it safe to run over gam formulas
#' without parsing the smooth terms. (all.names() would return "s" and
#' "+", which is why it is the wrong function here.)
#'
#' The union across ALL specs, not per spec, because the scoring
#' population has to be shared. A row missing a stage-4 feature is
#' excluded from stage 1 as well, or the deltas compare different
#' datasets.
#'
#' Note that derived columns carry the requirement of their inputs:
#' `dist_to_sticks` is complete exactly when air_yards and yards_to_go
#' both are, so `yards_to_go` acquiring missingness is caught here
#' under the derived name rather than its own.
#'
#' @param specs A list like MODEL_SPECS.
#' @param extra Additional columns the harness itself needs — fold
#'   grouping and the play keys. These are part of the population
#'   requirement even though no formula names them.
#' @return Character vector of unique column names, response included.
model_vars <- function(
  specs = MODEL_SPECS,
  extra = c("game_id", "play_id", "week")
) {
  from_formulas <- unlist(lapply(specs, \(s) all.vars(s$formula)))
  unique(c(from_formulas, extra))
}


#' Fail if any required column is missing or incomplete
#'
#' Two failure modes, deliberately distinguished in the message,
#' because they have different causes. An ABSENT column means the spec
#' and the frame disagree — usually a feature script that has not run
#' yet. An INCOMPLETE column means the population needs a decision,
#' which belongs in scripts/08_build_model_frame.R with a funnel flag
#' and a count, not in a filter() here.
#'
#' THIS ASSERTS RATHER THAN FILTERS, on purpose. Dropping rows is an
#' exclusion, exclusions are checked for differential completion rates
#' and logged with counts (notes/decisions.md §4.7), and the modeling
#' layer is not allowed to change the population silently. glm() and
#' gam() default to na.action = na.omit, which would do exactly that.
#'
#' Called before make_folds(), so the folds and every fit see one
#' population.
#'
#' @param df The candidate scoring population.
#' @param vars Required columns. Defaults to model_vars().
#' @return `df`, invisibly.
assert_complete <- function(df, vars = model_vars()) {
  absent <- setdiff(vars, names(df))
  if (length(absent)) {
    stop(
      "Columns required by MODEL_SPECS are absent from the model frame: ",
      paste0(absent, collapse = ", "),
      ".",
      call. = FALSE
    )
  }

  n_na <- vapply(df[vars], \(x) sum(is.na(x)), integer(1))
  bad <- n_na[n_na > 0]

  if (length(bad)) {
    stop(
      "Incomplete columns in the model frame: ",
      paste0(names(bad), " (", bad, ")", collapse = ", "),
      ". glm() and gam() would drop these rows per stage, so stages ",
      "would be scored on different populations. Resolve the ",
      "population in scripts/08_build_model_frame.R — see ",
      "incomplete_report() for the outcome composition — rather than ",
      "filtering here.",
      call. = FALSE
    )
  }

  invisible(df)
}


#' What a complete-case restriction would cost, and whether it is
#' selected on outcome
#'
#' The reporting counterpart to assert_complete(). Every exclusion in
#' this project is checked for differential completion rates before
#' adoption (notes/decisions.md §4.7), and a drop performed at fit time
#' escapes that check entirely. This function is what makes the drop a
#' logged decision.
#'
#' @param df Candidate population, before any restriction.
#' @param vars Required columns. Defaults to model_vars().
#' @param outcome Response column, compared between kept and dropped.
#' @return list(by_column = per-column NA counts,
#'              composition = outcome shares for kept vs dropped)
incomplete_report <- function(
  df,
  vars = model_vars(),
  outcome = "pass_result"
) {
  vars <- intersect(vars, names(df))

  by_column <- tibble::tibble(
    column = vars,
    n_missing = vapply(df[vars], \(x) sum(is.na(x)), integer(1)),
    pct_missing = vapply(df[vars], \(x) mean(is.na(x)), numeric(1))
  ) |>
    dplyr::filter(n_missing > 0) |>
    dplyr::arrange(dplyr::desc(n_missing))

  keep <- stats::complete.cases(df[vars])

  composition <- df |>
    dplyr::mutate(.kept = keep) |>
    dplyr::count(.kept, dplyr::across(dplyr::all_of(outcome))) |>
    dplyr::group_by(.kept) |>
    dplyr::mutate(share = n / sum(n)) |>
    dplyr::ungroup()

  list(by_column = by_column, composition = composition)
}


# ---- resampling --------------------------------------------------

#' Leave-one-group-out resampling folds
#'
#' One fold per level of `group`: fit on every other level, predict the
#' held-out one. Grouping on week rather than on plays because plays
#' within a game share an offense, a defense, and a game state, so a
#' random split lets the model see conditions from a test play's own
#' game and returns an optimistic estimate with no signature.
#'
#' No seed. With one group per fold there is no random assignment of
#' groups to folds; only the returned order could vary, and the sort at
#' the end removes that.
#'
#' @param df The final scoring population.
#' @param group Column defining the blocks. One name.
#' @return An rset with one row per fold, carrying `held_out`: the
#'   value of `group` in that fold's assessment set.
make_folds <- function(df, group = "week") {
  stopifnot(
    is.data.frame(df),
    length(group) == 1L,
    group %in% names(df),
    # group_vfold_cv() would happily make an extra fold out of the NA
    # level, whose training set is everything and whose test set is
    # garbage.
    !anyNA(df[[group]])
  )

  folds <- rsample::group_vfold_cv(df, group = tidyselect::all_of(group))

  # Which level each fold holds out. rsample labels folds
  # "Resample01"..."Resample17", which says nothing about which week
  # that is, and the per-fold spread is uninterpretable without it.
  held <- purrr::map(folds$splits, \(s) unique(rsample::assessment(s)[[group]]))

  # Exactly one level per assessment set is the definition of
  # leave-one-out on this grouping. If this fires, `group` is not doing
  # what it looks like.
  stopifnot(all(lengths(held) == 1L))

  folds$held_out <- unlist(held)

  # Sorted so fold order is the natural order of the group, whatever
  # order rsample returned them in.
  folds[order(folds$held_out), ]
}


# ---- fitting -----------------------------------------------------

#' Fit one spec to one dataset
#'
#' Dispatches on the spec's engine. glm() for the intercept model
#' because it needs no basis expansion and using it makes the floor
#' unambiguous; gam() for everything else.
#'
#' method = "REML" overrides mgcv's "GCV.Cp" default. GCV can select a
#' spurious local optimum and undersmooth badly; REML is the more
#' stable criterion and is what mgcv's author recommends. This is the
#' most consequential single argument in the file.
#'
#' na.action = na.fail rather than the na.omit default. assert_complete()
#' already guarantees completeness on the full frame, but that runs once
#' while this runs 17 times on subsets, and a silently shrunken training
#' fold is exactly the failure this harness exists to prevent.
fit_one <- function(spec, data) {
  stopifnot(spec$engine %in% c("glm", "gam"))

  if (spec$engine == "glm") {
    stats::glm(
      spec$formula,
      data = data,
      family = stats::binomial(),
      na.action = stats::na.fail
    )
  } else {
    mgcv::gam(
      spec$formula,
      data = data,
      family = stats::binomial(),
      method = "REML",
      na.action = stats::na.fail
    )
  }
}


#' Out-of-fold predictions for one spec on one fold
#'
#' type = "response" returns probabilities. The default for a binomial
#' fit is the LINK scale, i.e. log-odds, and feeding those to a log-loss
#' function produces a plausible-looking number that means nothing. This
#' is the easiest place in the harness to be silently wrong.
#'
#' @return The assessment rows, carrying keys, outcome, and `.pred`.
fit_fold <- function(split, spec, keys = c("game_id", "play_id", "week")) {
  train <- rsample::analysis(split)
  test <- rsample::assessment(split)

  fit <- fit_one(spec, train)

  p <- stats::predict(fit, newdata = test, type = "response")

  # A length mismatch means predict() dropped rows despite na.fail, or
  # returned a matrix. Either way the join downstream would be wrong in
  # a way that is hard to see. A prediction of exactly 0 or 1 makes log
  # loss infinite.
  stopifnot(
    length(p) == nrow(test),
    !anyNA(p),
    all(p > 0 & p < 1)
  )

  test |>
    dplyr::select(dplyr::all_of(c(keys, "complete"))) |>
    dplyr::mutate(
      .pred = as.numeric(p),
      n_train = nrow(train)
    )
}


#' Pooled out-of-fold predictions for one spec across all folds
#'
#' Every play appears exactly once, predicted by a fit that did not see
#' its week. Pooling rather than averaging per-fold metrics is
#' deliberate: with folds of unequal size the mean of fold log losses
#' and the log loss of pooled predictions are different numbers, and
#' only the pooled version can be subset afterwards (to has_cp, to
#' separation buckets) without refitting.
#'
#' Progress is messaged per fold so that a convergence warning is
#' attributable to a week rather than appearing anonymously after all
#' 17 fits.
#'
#' @return One row per play: keys, `complete`, `.pred`, `model`.
cv_predict <- function(df, folds, spec, name, verbose = TRUE) {
  preds <- purrr::map2(
    folds$splits,
    folds$held_out,
    \(split, held) {
      if (verbose) {
        message("  ", name, " — holding out week ", held)
      }
      fit_fold(split, spec)
    }
  ) |>
    purrr::list_rbind()

  stopifnot(
    nrow(preds) == nrow(df),
    !any(duplicated(preds[c("game_id", "play_id")]))
  )

  dplyr::mutate(preds, model = name)
}


#' Every spec, cross-validated, stacked
#'
#' @return One row per (play, model).
cv_predict_all <- function(df, folds, specs = MODEL_SPECS, verbose = TRUE) {
  purrr::imap(
    specs,
    \(spec, name) cv_predict(df, folds, spec, name, verbose = verbose)
  ) |>
    purrr::list_rbind()
}


#' One fit on the whole sample, for interpretation rather than scoring
#'
#' The 17 cross-validation fits are discarded — their only product is
#' the prediction table. Diagnostics, effective degrees of freedom,
#' smooth plots, and summary() all want a single fit on all the data.
#' Keeping the two separate avoids either interpreting a model fit on
#' 16/17 of the sample or producing 17 sets of diagnostics.
#'
#' Nothing here is out-of-sample. Do not report a metric from this fit.
fit_full <- function(df, spec) {
  fit_one(spec, df)
}
