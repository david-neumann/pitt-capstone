# R/utils.R ------------------------------------------------------------
# Project-wide utilities with no domain content. Defines functions only —
# no library() calls, no side effects.

#' Identifier columns that must share a type across the processed layer
KEY_COLS <- c(
  "game_id",
  "play_id",
  "nfl_id",
  "frame_id",
  "target_nfl_id",
  "week"
)

# camelCase -> snake_case
to_snake <- function(x) {
  tolower(gsub("([a-z0-9])([A-Z])", "\\1_\\2", x))
}

#' Cast identifier columns to integer
#'
#' Arrow stores the BDB identifiers as int64. Reading them into R yields
#' integer64 or double depending on whether bit64 happens to be loaded,
#' and a type mismatch on a join key produces zero matches rather than an
#' error. Casting everything to int32 at the point of collection removes
#' the whole class of bug, and removes the scattered
#' `mutate(across(..., as.integer))` calls that currently guard each join.
#'
#' gameId is the largest identifier in the dataset (e.g. 2018090600) and
#' fits comfortably inside int32's 2147483647 ceiling.
cast_keys <- function(df, cols = KEY_COLS) {
  dplyr::mutate(df, dplyr::across(dplyr::any_of(cols), as.integer))
}

#' Add missing columns as all-NA
#'
#' pivot_wider() only creates columns for values that actually occur. An
#' anchor event absent from every play in the dataset yields no column at
#' all, and downstream code referring to it errors instead of seeing NA.
ensure_cols <- function(df, cols, fill = NA_integer_) {
  missing <- setdiff(cols, names(df))
  for (nm in missing) {
    df[[nm]] <- fill
  }
  df
}
