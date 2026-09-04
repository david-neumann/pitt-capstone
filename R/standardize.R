# Field constants, in yards. Length includes both end zones.
FIELD_LENGTH <- 120
FIELD_WIDTH <- 160 / 3

# camelCase -> snake_case
to_snake <- function(x) {
  tolower(gsub("([a-z0-9])([A-Z])", "\\1_\\2", x))
}

#' Rotate left-moving plays 180 degrees so every offense advances in +x
#'
#' Reflecting BOTH x and y is a rotation, not a mirror. Flipping only x
#' would mirror the field and silently swap offensive left and right,
#' which is a bug that produces entirely plausible-looking output.
#' Angles shift by 180 degrees under the same rotation, which holds
#' regardless of where the angle convention places zero.
standardize_direction <- function(df) {
  flip <- df$play_direction == "left"
  df |>
    mutate(
      x = if_else(flip, FIELD_LENGTH - x, x),
      y = if_else(flip, FIELD_WIDTH - y, y),
      dir = if_else(flip, (dir + 180) %% 360, dir),
      o = if_else(flip, (o + 180) %% 360, o)
    )
}

#' Flip a line-of-scrimmage value into standardized coordinates
standardize_los <- function(los, play_direction) {
  if_else(play_direction == "left", FIELD_LENGTH - los, los)
}
