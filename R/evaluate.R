# R/evaluate.R -----------------------------------------------------
# Cross-validation harness and scoring for the completion model.
#
# Every function assumes the final scoring population: one row per play
# and no missing values in any variable used by any model spec, so that
# every stage is fit and scored on the same rows.
#
# Workflow order:
#
#   prepare_model_frame()   response and derived predictors
#   MODEL_SPECS             the nested stages
#   model_vars()            columns the specs require
#   assert_complete()       fail on an incomplete population
#   incomplete_report()     cost of a complete-case restriction
#   make_folds()            leave-one-week-out folds
#   fit_one() / fit_fold()  a single fit
#   cv_predict()            out-of-fold predictions, one spec
#   cv_predict_all()        out-of-fold predictions, every spec
#   fit_full()              one fit on all rows, for interpretation
#   pointwise_log_loss()    per-play log loss
#   log_loss()              mean log loss
#   paired_delta()          paired difference with a cluster bootstrap
#   calibration_stats()     calibration-in-the-large, intercept, slope
#   calibration_summary()   the same with a cluster bootstrap interval
#   calibration_curve()     binned and smoothed reliability curves
#   air_yards_bucket()      subgroup buckets for calibration
#
# mgcv must be attached (library(mgcv)) before fitting, because the spec
# formulas use bare s().

# ---- model frame -------------------------------------------------

#' Add the response and derived predictors
#'
#' - `complete` is 1 for C and 0 for I and IN, matching nflverse `cp`.
#' - Factor levels with fewer than `min_level_n` plays are lumped into
#'   "other", so no level can be absent from a training fold. NA stays
#'   NA, so assert_complete() still sees it.
#' - `number_of_pass_rushers` is clamped to `rush_range`; the tails hold
#'   a handful of plays and would otherwise be extrapolated in some folds.
#' - `dist_to_sticks = air_yards - yards_to_go` replaces `yards_to_go`,
#'   since all three together are linearly dependent.
#' - `air_yards_zero` flags throws at exactly zero air yards, a point
#'   mass a penalized smooth cannot capture.
#' - `home` is 1 when the offense is the home team.
#'
#' @param df Throws with `pass_result` in C, I, IN and the predictor
#'   columns.
#' @param min_level_n Minimum plays per factor level.
#' @param rush_range Clamp range for `number_of_pass_rushers`.
#' @return `df` with the response and derived columns added.
prepare_model_frame <- function(
  df,
  min_level_n = 100,
  rush_range = c(2, 7)
) {
  stopifnot(
    all(df$pass_result %in% c("C", "I", "IN")),
    !anyNA(df$pass_result),
    # Used as a numeric `by` variable; a factor would fit one smooth per
    # level instead.
    is.numeric(df$qb_hit)
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
      dist_to_sticks = air_yards - yards_to_go,
      air_yards_zero = as.integer(air_yards == 0),
      home = as.integer(posteam_type == "home")
    )
}


# ---- the stages --------------------------------------------------

#' Nested model stages
#'
#' Each entry has an `engine` ("glm" or "gam") and a `formula`. Stages are
#' nested so each adds information to the one before; stage 2 includes
#' throw depth so that later stages are credited only with coverage
#' information. Terms are chosen by argument, not by in-sample
#' significance.
#'
#' Stage 2 follows the nflverse `cp` feature set where the data allow,
#' with these differences:
#'
#' - `pass_location` keeps three levels rather than middle/not-middle.
#' - `number_of_pass_rushers` is added as a defensive control.
#' - `roof` and era are omitted.
#' - `offense_formation` is excluded: it describes scheme rather than
#'   difficulty and is aliased with `shotgun`.
#' - `defenders_in_the_box` and `score_differential` are excluded.
#' - `s(dist_to_sticks)` is kept although it fits as nearly linear; it is
#'   the model's only `yards_to_go` information.
#' - `qb_hit` enters as `s(air_yards, by = qb_hit)`, because its effect
#'   weakens with depth (notes/decisions.md §9.3). A smooth with a numeric
#'   `by` is not centered, so it carries the level of the hit effect and
#'   there is no separate `qb_hit` term.
#'
#' `air_yards` is charted rather than measured and will be replaced by
#' the tracking-derived throw distance once that exists. Fitted effects
#' are reported in analysis/03_model_baseline.qmd §3.
#'
#' Stages 3 (separation) and 4 (full geometry) are added once their
#' feature columns exist.
MODEL_SPECS <- list(
  `1. intercept` = list(
    engine = "glm",
    formula = complete ~ 1
  ),

  # k = 5 because the clamped rusher count takes only six values.
  `2. play-by-play` = list(
    engine = "gam",
    formula = complete ~
      s(air_yards) +
      s(dist_to_sticks) +
      s(los_x) +
      s(number_of_pass_rushers, k = 5) +
      s(air_yards, by = qb_hit) +
      air_yards_zero +
      down +
      pass_location +
      shotgun +
      home
  )
)


# ---- the scoring population --------------------------------------

#' Every column required by any model spec
#'
#' The union across specs, because all stages must share one population.
#' all.vars() returns variable names only, so smooth terms such as
#' `s(x, k = 5)` contribute `x`.
#'
#' @param specs A list like MODEL_SPECS.
#' @param extra Columns the harness needs beyond the formulas (keys and
#'   the fold grouping).
#' @return Character vector of unique column names, response included.
model_vars <- function(
  specs = MODEL_SPECS,
  extra = c("game_id", "play_id", "week")
) {
  from_formulas <- unlist(lapply(specs, \(s) all.vars(s$formula)))
  unique(c(from_formulas, extra))
}


#' Fail if any required column is absent or contains NA
#'
#' Asserts rather than filters: glm() and gam() would otherwise drop
#' incomplete rows per stage, so stages would be scored on different
#' populations. Resolve missingness when building the model frame and
#' report it with incomplete_report().
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


#' Missingness and kept-versus-dropped outcome composition
#'
#' Reports what restricting to complete cases would remove, and whether
#' the removed rows differ in outcome.
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

#' Leave-one-group-out folds
#'
#' One fold per level of `group`. Grouping by week keeps plays from the
#' same game out of each other's training sets. Deterministic: folds are
#' sorted by the held-out level.
#'
#' @param df The final scoring population.
#' @param group Name of the grouping column.
#' @return An rset with one row per fold and a `held_out` column giving
#'   that fold's level of `group`.
make_folds <- function(df, group = "week") {
  stopifnot(
    is.data.frame(df),
    length(group) == 1L,
    group %in% names(df),
    # An NA level would become its own fold.
    !anyNA(df[[group]])
  )

  folds <- rsample::group_vfold_cv(df, group = tidyselect::all_of(group))

  held <- purrr::map(folds$splits, \(s) unique(rsample::assessment(s)[[group]]))

  stopifnot(all(lengths(held) == 1L))

  folds$held_out <- unlist(held)

  folds[order(folds$held_out), ]
}


# ---- fitting -----------------------------------------------------

#' Fit one spec
#'
#' Binomial glm() or gam() according to `spec$engine`. GAMs use REML
#' smoothness selection. `na.action = na.fail` so a fit never drops rows
#' silently.
#'
#' @param spec One entry of MODEL_SPECS.
#' @param data Training rows.
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


#' Fit on one fold's analysis set and predict its assessment set
#'
#' Predictions are probabilities (`type = "response"`), checked to be
#' complete and strictly inside (0, 1).
#'
#' @param split An rsample split.
#' @param spec One entry of MODEL_SPECS.
#' @param keys Columns carried through to the output.
#' @return The assessment rows' keys and `complete`, plus `.pred` and
#'   `n_train`.
fit_fold <- function(split, spec, keys = c("game_id", "play_id", "week")) {
  train <- rsample::analysis(split)
  test <- rsample::assessment(split)

  fit <- fit_one(spec, train)

  p <- stats::predict(fit, newdata = test, type = "response")

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


#' Pooled out-of-fold predictions for one spec
#'
#' Every play is predicted once, by the fit that excluded its fold.
#' Metrics are computed on the pooled predictions rather than averaged
#' across folds, which also allows scoring any subset without refitting.
#'
#' @param df The scoring population `folds` was built from.
#' @param folds Output of make_folds().
#' @param spec One entry of MODEL_SPECS.
#' @param name Stage name, stored in `model`.
#' @param verbose Message each held-out fold.
#' @return One row per play: keys, `complete`, `.pred`, `n_train`,
#'   `model`.
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


#' Out-of-fold predictions for every spec, stacked
#'
#' @inheritParams cv_predict
#' @param specs A list like MODEL_SPECS.
#' @return One row per (play, model).
cv_predict_all <- function(df, folds, specs = MODEL_SPECS, verbose = TRUE) {
  purrr::imap(
    specs,
    \(spec, name) cv_predict(df, folds, spec, name, verbose = verbose)
  ) |>
    purrr::list_rbind()
}


#' Fit one spec on all rows, for interpretation
#'
#' In-sample only; not for reporting performance.
fit_full <- function(df, spec) {
  fit_one(spec, df)
}


# ---- scoring -----------------------------------------------------

#' Per-play log loss, in nats
#'
#' -[y log(p) + (1 - y) log(1 - p)] for each play. Probabilities are not
#' clipped: a prediction of exactly 0 or 1 is an error. Implemented
#' directly rather than with yardstick::mn_log_loss(), which clips by
#' default and treats the first factor level ("0") as the event.
#'
#' @param y Observed outcome, 0 or 1.
#' @param p Predicted probability that y = 1, strictly inside (0, 1).
#' @return Numeric vector the length of `y`.
pointwise_log_loss <- function(y, p) {
  assert_probs(y, p)

  -(y * log(p) + (1 - y) * log1p(-p))
}


#' Fail unless `y` is a complete 0/1 vector and `p` a matching vector of
#' probabilities strictly inside (0, 1)
assert_probs <- function(y, p) {
  stopifnot(
    length(y) == length(p),
    length(y) > 0,
    !anyNA(y),
    !anyNA(p),
    all(y %in% c(0, 1)),
    all(p > 0 & p < 1)
  )
  invisible(TRUE)
}


#' Mean log loss, in nats
#'
#' A constant prediction at the base rate ybar scores the binary entropy
#' H(ybar). Leave-one-week-out intercept-only predictions cannot score
#' below it, which makes it a check on the folds.
#'
#' @inheritParams pointwise_log_loss
log_loss <- function(y, p) {
  mean(pointwise_log_loss(y, p))
}


#' Paired difference in log loss between two stages, with a cluster
#' bootstrap interval
#'
#' For each play, d_i = loss under `model` minus loss under `reference`;
#' the estimate is mean(d_i), so negative values favour `model`. Pairing
#' removes the play-level difficulty both stages share.
#'
#' The interval resamples whole clusters with replacement and is the
#' percentile interval of the resampled means (each the sum of d_i over
#' the drawn clusters divided by the number of plays drawn). It treats
#' the out-of-fold predictions as fixed, so it reflects sampling
#' variability in the plays, not refitting variability. Percentile
#' intervals are too narrow when clusters are few.
#'
#' Two standard errors are reported for comparison: `se_cluster`, the
#' analytic cluster-robust standard error of a mean, which should be
#' close to `se_boot`; and `se_iid`, which ignores clustering.
#'
#' @param preds Output of cv_predict_all(): one row per (play, model)
#'   with `game_id`, `play_id`, `complete`, `.pred`, `model`, and the
#'   cluster column.
#' @param reference,model Values of `preds$model` to compare.
#' @param cluster Name of the column defining resampling clusters.
#' @param B Bootstrap resamples.
#' @param level Interval coverage.
#' @param seed RNG seed, applied locally.
#' @return A one-row tibble: `reference`, `model`, `cluster`,
#'   `n_clusters`, `n`, `estimate`, `conf_low`, `conf_high`, `se_boot`,
#'   `se_cluster`, `se_iid`.
paired_delta <- function(
  preds,
  reference,
  model,
  cluster = "game_id",
  B = 10000,
  level = 0.95,
  seed = 1961
) {
  stopifnot(
    length(cluster) == 1L,
    cluster %in% names(preds),
    all(c(reference, model) %in% preds$model),
    B >= 1000,
    level > 0 && level < 1
  )

  keys <- c("game_id", "play_id")
  ref <- preds[
    preds$model == reference,
    unique(c(keys, cluster, "complete", ".pred"))
  ]
  mod <- preds[preds$model == model, c(keys, "complete", ".pred")]

  paired <- dplyr::inner_join(ref, mod, by = keys, suffix = c("_ref", "_mod"))

  # Both stages must be scored on exactly the same plays and outcomes.
  stopifnot(
    nrow(paired) == nrow(ref),
    nrow(paired) == nrow(mod),
    identical(paired$complete_ref, paired$complete_mod),
    !anyNA(paired[[cluster]])
  )

  d <- pointwise_log_loss(paired$complete_mod, paired$.pred_mod) -
    pointwise_log_loss(paired$complete_ref, paired$.pred_ref)
  g <- paired[[cluster]]

  sums <- as.numeric(rowsum(d, g))
  sizes <- as.numeric(rowsum(rep(1, length(d)), g))
  n_g <- length(sums)
  n <- length(d)
  estimate <- mean(d)

  draws <- withr::with_seed(seed, {
    idx <- matrix(sample.int(n_g, n_g * B, replace = TRUE), nrow = B)
    rowSums(matrix(sums[idx], nrow = B)) /
      rowSums(matrix(sizes[idx], nrow = B))
  })

  alpha <- 1 - level
  ci <- stats::quantile(draws, c(alpha / 2, 1 - alpha / 2), names = FALSE)

  tibble::tibble(
    reference = reference,
    model = model,
    cluster = cluster,
    n_clusters = n_g,
    n = n,
    estimate = estimate,
    conf_low = ci[1],
    conf_high = ci[2],
    se_boot = stats::sd(draws),
    se_cluster = sqrt(n_g / (n_g - 1) * sum((sums - sizes * estimate)^2)) / n,
    se_iid = stats::sd(d) / sqrt(n)
  )
}


# ---- calibration -------------------------------------------------

#' Logistic recalibration statistics
#'
#' - `citl`: calibration-in-the-large, mean(y) - mean(p). Positive when
#'   the model underpredicts.
#' - `intercept`: a in logit P(y = 1) = a + logit(p), with the slope fixed
#'   at 1. Zero when calibrated in the large; same sign as `citl`.
#' - `slope`: b in logit P(y = 1) = a + b logit(p). One when calibrated;
#'   below one when predictions are too extreme, above one when too
#'   timid.
#'
#' See Van Calster et al. (2019).
#'
#' @inheritParams pointwise_log_loss
#' @return Named numeric vector: `citl`, `intercept`, `slope`.
calibration_stats <- function(y, p) {
  assert_probs(y, p)
  lp <- stats::qlogis(p)

  fit_int <- stats::glm.fit(
    x = matrix(1, nrow = length(y)),
    y = y,
    offset = lp,
    family = stats::binomial()
  )
  fit_slope <- stats::glm.fit(
    x = cbind(1, lp),
    y = y,
    family = stats::binomial()
  )
  stopifnot(fit_int$converged, fit_slope$converged)

  c(
    citl = mean(y) - mean(p),
    intercept = fit_int$coefficients[[1]],
    slope = fit_slope$coefficients[[2]]
  )
}


#' Calibration statistics with a cluster bootstrap interval
#'
#' Resamples whole clusters with replacement and refits the recalibration
#' models on each draw; the interval is the percentile interval. As in
#' paired_delta(), predictions are held fixed.
#'
#' @inheritParams pointwise_log_loss
#' @param cluster Cluster label for each play, the length of `y`.
#' @param B Bootstrap resamples.
#' @param level Interval coverage.
#' @param seed RNG seed, applied locally.
#' @return A tibble with one row per statistic: `stat`, `estimate`,
#'   `conf_low`, `conf_high`, `n`, `n_clusters`.
calibration_summary <- function(
  y,
  p,
  cluster,
  B = 2000,
  level = 0.95,
  seed = 1961
) {
  stopifnot(
    length(cluster) == length(y),
    !anyNA(cluster),
    B >= 1000,
    level > 0 && level < 1
  )

  est <- calibration_stats(y, p)
  rows <- split(seq_along(y), cluster)
  n_g <- length(rows)

  draws <- withr::with_seed(seed, {
    vapply(
      seq_len(B),
      \(b) {
        i <- unlist(rows[sample.int(n_g, n_g, replace = TRUE)], use.names = FALSE)
        calibration_stats(y[i], p[i])
      },
      numeric(3)
    )
  })

  alpha <- 1 - level
  ci <- apply(draws, 1, stats::quantile, probs = c(alpha / 2, 1 - alpha / 2))

  tibble::tibble(
    stat = names(est),
    estimate = unname(est),
    conf_low = unname(ci[1, ]),
    conf_high = unname(ci[2, ]),
    n = length(y),
    n_clusters = n_g
  )
}


#' Binned and smoothed calibration curves
#'
#' Bins have equal counts of plays, so each point carries similar
#' precision. The smooth is a binomial GAM of `y` on logit(p), evaluated
#' between the 0.5th and 99.5th percentiles of `p`, with a pointwise
#' band that ignores clustering.
#'
#' @inheritParams pointwise_log_loss
#' @param n_bins Number of equal-count bins.
#' @param n_grid Points at which the smooth is evaluated.
#' @param level Band coverage.
#' @return list(bins = tibble of `bin`, `n`, `mean_pred`, `obs_rate`,
#'   `se`; smooth = tibble of `pred`, `obs`, `low`, `high`).
calibration_curve <- function(y, p, n_bins = 20, n_grid = 200, level = 0.95) {
  assert_probs(y, p)

  bins <- tibble::tibble(y = y, p = p) |>
    dplyr::mutate(bin = dplyr::ntile(p, n_bins)) |>
    dplyr::group_by(bin) |>
    dplyr::summarize(
      n = dplyr::n(),
      mean_pred = mean(p),
      obs_rate = mean(y),
      .groups = "drop"
    ) |>
    dplyr::mutate(se = sqrt(obs_rate * (1 - obs_rate) / n))

  fit <- mgcv::gam(
    y ~ s(lp),
    data = data.frame(y = y, lp = stats::qlogis(p)),
    family = stats::binomial(),
    method = "REML"
  )

  grid <- seq(
    stats::quantile(p, 0.005, names = FALSE),
    stats::quantile(p, 0.995, names = FALSE),
    length.out = n_grid
  )
  pr <- stats::predict(
    fit,
    newdata = data.frame(lp = stats::qlogis(grid)),
    se.fit = TRUE
  )
  z <- stats::qnorm(1 - (1 - level) / 2)

  smooth <- tibble::tibble(
    pred = grid,
    obs = stats::plogis(pr$fit),
    low = stats::plogis(pr$fit - z * pr$se.fit),
    high = stats::plogis(pr$fit + z * pr$se.fit)
  )

  list(bins = bins, smooth = smooth)
}


#' Air-yards buckets for subgroup calibration
#'
#' Fixed football-meaningful edges: at or behind the line, short,
#' intermediate, deep.
#'
#' @param air_yards Numeric vector.
#' @return Factor with levels "<= 0", "1-9", "10-19", "20+".
air_yards_bucket <- function(air_yards) {
  cut(
    air_yards,
    breaks = c(-Inf, 0, 9, 19, Inf),
    labels = c("<= 0", "1-9", "10-19", "20+"),
    right = TRUE
  )
}
