# scripts/09_fit_models.R ----------------------------------------------
# Fits every stage in MODEL_SPECS once: leave-one-week-out out-of-fold
# predictions for scoring, and one fit on all rows for interpretation.
#
# The notebooks read these instead of refitting. read_oof_preds() and
# read_full_fits() in R/evaluate.R fail if MODEL_SPECS or the model frame
# has changed since this script ran, so a stale result cannot be reported
# (notes/decisions.md §9.4).
#
# Outputs:
#   data/processed/oof_preds.parquet  one row per (play, stage): keys,
#                                     `complete`, `.pred`, `n_train`, `model`
#   data/processed/oof_specs.parquet  one row per stage: the spec as text,
#                                     the model-input hash, versions
#   models/full_fits.rds              named list, one fit on all rows per
#                                     stage
#
# Run after 08_build_model_frame.R.

library(arrow)
library(dplyr)
library(fs)
library(here)
# The spec formulas use bare s() and ti().
library(mgcv)

source(here("R", "constants.R"))
source(here("R", "utils.R"))
source(here("R", "evaluate.R"))

processed <- here("data", "processed")
models_dir <- here("models")
dir_create(models_dir)

model_frame <- read_parquet(path(processed, "model_frame.parquet"))
assert_complete(model_frame)

folds <- make_folds(model_frame)

oof_preds <- cv_predict_all(model_frame, folds)

full_fits <- lapply(names(MODEL_SPECS), \(name) {
  message("  ", name, " — all rows")
  fit_full(model_frame, MODEL_SPECS[[name]])
}) |>
  setNames(names(MODEL_SPECS))

oof_specs <- spec_table() |>
  mutate(
    n = nrow(model_frame),
    input_hash = model_input_hash(model_frame),
    r_version = as.character(getRversion()),
    mgcv_version = as.character(packageVersion("mgcv")),
    fitted_at = Sys.time()
  )

stopifnot(
  nrow(oof_preds) == nrow(model_frame) * length(MODEL_SPECS),
  !any(duplicated(oof_preds[c("game_id", "play_id", "model")])),
  identical(unique(oof_preds$model), names(MODEL_SPECS)),
  identical(names(full_fits), names(MODEL_SPECS))
)

write_parquet(oof_preds, path(processed, "oof_preds.parquet"))
write_parquet(oof_specs, path(processed, "oof_specs.parquet"))
saveRDS(full_fits, path(models_dir, "full_fits.rds"))

# The readers must return exactly what was written.
stopifnot(
  isTRUE(all.equal(
    filter(read_oof_preds(model_frame), model != "cp"),
    oof_preds
  )),
  identical(names(read_full_fits(model_frame)), names(MODEL_SPECS))
)

print(as.data.frame(
  oof_preds |>
    group_by(model) |>
    summarize(n = n(), log_loss = log_loss(complete, .pred))
))

message(
  "Done. ",
  length(MODEL_SPECS),
  " stages on ",
  nrow(model_frame),
  " plays; full_fits.rds is ",
  format(file_size(path(models_dir, "full_fits.rds"))),
  "."
)
