# R/utils.R ------------------------------------------------------------
# General-purpose helpers.

#' Identifier columns that must share a type across the processed layer
KEY_COLS <- c(
  "game_id",
  "play_id",
  "nfl_id",
  "frame_id",
  "target_nfl_id",
  "week"
)

#' Fail if a table lacks expected columns
#'
#' @param df A data frame.
#' @param cols Required column names.
#' @param what Name of the table, used in the error message.
#' @return `df`, invisibly.
require_cols <- function(df, cols, what) {
  missing <- setdiff(cols, names(df))
  if (length(missing)) {
    stop(what, " missing expected columns: ", paste0(missing, collapse = ", "))
  }
  invisible(df)
}

#' Convert camelCase to snake_case
to_snake <- function(x) {
  tolower(gsub("([a-z0-9])([A-Z])", "\\1_\\2", x))
}

#' Cast identifier columns to integer
#'
#' Arrow stores identifiers as int64, which collect into R as integer64
#' or double depending on whether bit64 is loaded. Joining on mismatched
#' key types returns zero matches rather than an error, so every key is
#' cast to int32 when collected. The largest identifier (`game_id`, e.g.
#' 2018090600) fits within the int32 range.
#'
#' @param df A data frame.
#' @param cols Columns to cast, where present.
cast_keys <- function(df, cols = KEY_COLS) {
  dplyr::mutate(df, dplyr::across(dplyr::any_of(cols), as.integer))
}

#' Add missing columns as all-NA
#'
#' `pivot_wider()` only creates columns for values that occur, so an event
#' absent from every play would otherwise produce no column at all.
ensure_cols <- function(df, cols, fill = NA_integer_) {
  missing <- setdiff(cols, names(df))
  for (nm in missing) {
    df[[nm]] <- fill
  }
  df
}
