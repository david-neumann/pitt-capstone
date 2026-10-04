# R/standardize.R ------------------------------------------------------
# Coordinate-frame normalization.

source(here::here("R", "constants.R"))

#' Rotate left-moving plays so every offense advances toward +x
#'
#' Reflects both `x` and `y`, which is a 180-degree rotation. Reflecting
#' `x` alone would mirror the field and swap the offense's left and
#' right. `dir` and `o` shift by 180 degrees.
#'
#' Errors on a missing `play_direction`, since `if_else()` would otherwise
#' set every coordinate on that play to NA.
#'
#' @param df Tracking rows with `play_direction`, `x`, `y`, `dir`, `o`.
#' @return `df` with standardized `x`, `y`, `dir`, `o`.
standardize_direction <- function(df) {
  if (anyNA(df$play_direction)) {
    stop(
      "play_direction has ",
      sum(is.na(df$play_direction)),
      " missing values; rotation would silently NA out those coordinates.",
      call. = FALSE
    )
  }

  flip <- df$play_direction == "left"
  df |>
    dplyr::mutate(
      x = dplyr::if_else(flip, FIELD_LENGTH - x, x),
      y = dplyr::if_else(flip, FIELD_WIDTH - y, y),
      dir = dplyr::if_else(flip, (dir + 180) %% 360, dir),
      o = dplyr::if_else(flip, (o + 180) %% 360, o)
    )
}

#' Convert a line-of-scrimmage x value to standardized coordinates
standardize_los <- function(los, play_direction) {
  dplyr::if_else(play_direction == "left", FIELD_LENGTH - los, los)
}
