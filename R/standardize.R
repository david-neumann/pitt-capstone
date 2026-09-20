# R/standardize.R ------------------------------------------------------
# Coordinate-frame normalization. Defines functions only.

source(here::here("R", "constants.R"))

#' Rotate left-moving plays 180 degrees so every offense advances in +x
#'
#' Reflecting BOTH x and y is a rotation, not a mirror. Flipping only x
#' would mirror the field and silently swap offensive left and right,
#' which is a bug that produces entirely plausible-looking output.
#' Angles shift by 180 degrees under the same rotation, which holds
#' regardless of where the angle convention places zero.
#'
#' The play_direction guard matters because if_else() propagates an NA
#' condition into an NA result: a single unresolved play_direction would
#' blank x, y, dir, and o for every row of that play rather than erroring.
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

#' Flip a line-of-scrimmage value into standardized coordinates
standardize_los <- function(los, play_direction) {
  dplyr::if_else(play_direction == "left", FIELD_LENGTH - los, los)
}
