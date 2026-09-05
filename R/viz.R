# R/viz.R --------------------------------------------------------------
# Plotting helpers for BDB tracking data.
#
# PRECONDITION: every function here assumes coordinates have already
# passed through standardize_direction() in R/standardize.R, i.e. the
# offense always advances toward +x. Passing raw left-direction plays
# will render mirrored, and it will look plausible.
#
# Depends on R/constants.R for field geometry.
# team_fill_palette() calls nflreadr::load_teams(), which needs network
# access on first use and then caches for the session.

library(ggplot2)
library(dplyr)
library(gganimate)

source(here::here("R", "constants.R"))

# ---- team colours -----------------------------------------------------

.viz_cache <- new.env(parent = emptyenv())

#' Team metadata (abbreviations, colours), cached per session
team_lookup <- function() {
  if (is.null(.viz_cache$teams)) {
    # current = FALSE includes historical franchises, which matters for
    # a 2018 season dataset.
    .viz_cache$teams <- nflreadr::load_teams(current = FALSE)
  }
  .viz_cache$teams
}

#' Perceptual distance between two colours, in CIE Lab
#'
#' Lab rather than RGB because RGB distance doesn't track what the eye
#' actually discriminates: two colours can be far apart in RGB and still
#' read as identical on a projector.
lab_dist <- function(c1, c2) {
  m <- t(grDevices::col2rgb(c(c1, c2)))
  lab <- farver::convert_colour(m, from = "rgb", to = "lab")
  sqrt(sum((lab[1, ] - lab[2, ])^2))
}

#' Named fill palette for a single matchup
#'
#' Team colour palettes assume one team per chart. Putting two teams on
#' one field breaks that assumption — plenty of matchups have near
#' identical primaries (ATL/TB, SF/KC, ARI/WAS). When the primaries are
#' too close, fall back to team_b's secondary.
#'
#' @param min_dist Lab distance below which the primaries are treated as
#'   indistinguishable. 30 is roughly "clearly different at a glance".
team_fill_palette <- function(team_a, team_b, min_dist = 30) {
  teams <- team_lookup()

  col_of <- function(tm, which) {
    row <- teams[teams$team_abbr == tm, ]
    if (nrow(row) == 0) {
      stop(
        "Unknown team abbreviation: ",
        tm,
        ". Check against nflplotR::valid_team_names().",
        call. = FALSE
      )
    }
    row[[which]][1]
  }

  a <- col_of(team_a, "team_color")
  b <- col_of(team_b, "team_color")

  if (lab_dist(a, b) < min_dist) {
    b_alt <- col_of(team_b, "team_color2")
    if (lab_dist(a, b_alt) > lab_dist(a, b)) b <- b_alt
  }

  stats::setNames(c(a, b), c(team_a, team_b))
}

#' White or near-black label text, whichever contrasts with the fill
#'
#' Hardcoded white vanishes on light primaries (LAC powder blue, GB gold
#' as a secondary), so pick per-marker.
label_colour <- function(fill) {
  lum <- as.vector(t(grDevices::col2rgb(fill)) %*% c(0.2126, 0.7152, 0.0722))
  ifelse(lum > 140, "grey10", "white")
}

#' Resolve a palette from the data when the caller didn't supply one
resolve_palette <- function(df, pal = NULL, min_dist = 30) {
  if (!is.null(pal)) {
    return(pal)
  }
  abbrs <- sort(unique(stats::na.omit(df$team_abbr)))
  if (length(abbrs) != 2) {
    stop(
      "Expected exactly 2 teams, found ",
      length(abbrs),
      ". Filter to a single play first.",
      call. = FALSE
    )
  }
  team_fill_palette(abbrs[1], abbrs[2], min_dist = min_dist)
}

# ---- field ------------------------------------------------------------

#' Empty standardized field
#'
#' @param los_x Line of scrimmage in standardized coordinates (los_x
#'   from plays.parquet, not absolute_yardline_number).
#' @param yards_to_go Distance to the first-down marker.
#' @param xlim Visible window in x. Yard markings outside it are skipped
#'   rather than drawn and clipped, which keeps the grob count down —
#'   this matters when animating, since the field is redrawn per frame.
gg_field <- function(
  los_x = NULL,
  yards_to_go = NULL,
  xlim = c(0, FIELD_LENGTH),
  hash_marks = TRUE,
  sideline_ticks = TRUE,
  turf = "#4a7c47",
  endzone = "#3a6337"
) {
  five_yard <- seq(10, 110, by = 5)

  # Minor yards are the ones not already drawn as full-width lines.
  minor_yard <- setdiff(11:109, five_yard)
  minor_yard <- minor_yard[minor_yard >= xlim[1] & minor_yard <= xlim[2]]
  major_yard <- five_yard[five_yard >= xlim[1] & five_yard <= xlim[2]]

  p <- ggplot() +
    annotate(
      "rect",
      xmin = 0,
      xmax = FIELD_LENGTH,
      ymin = 0,
      ymax = FIELD_WIDTH,
      fill = turf
    ) +
    annotate(
      "rect",
      xmin = 0,
      xmax = 10,
      ymin = 0,
      ymax = FIELD_WIDTH,
      fill = endzone
    ) +
    annotate(
      "rect",
      xmin = 110,
      xmax = FIELD_LENGTH,
      ymin = 0,
      ymax = FIELD_WIDTH,
      fill = endzone
    )

  if (length(major_yard)) {
    p <- p +
      annotate(
        "segment",
        x = major_yard,
        xend = major_yard,
        y = 0,
        yend = FIELD_WIDTH,
        colour = "white",
        linewidth = 0.3,
        alpha = 0.6
      )
  }

  # Hash marks: short stubs of the yard line, centred on each hash row.
  if (hash_marks && length(minor_yard)) {
    hx <- rep(minor_yard, times = 2)
    hy <- rep(HASH_Y, each = length(minor_yard))
    p <- p +
      annotate(
        "segment",
        x = hx,
        xend = hx,
        y = hy - MARK_LEN / 2,
        yend = hy + MARK_LEN / 2,
        colour = "white",
        linewidth = 0.25,
        alpha = 0.7
      )
  }

  # Sideline ticks: same yard marks, extending inward from each sideline.
  if (sideline_ticks && length(minor_yard)) {
    tx <- rep(minor_yard, times = 2)
    ty0 <- rep(c(0, FIELD_WIDTH - MARK_LEN), each = length(minor_yard))
    p <- p +
      annotate(
        "segment",
        x = tx,
        xend = tx,
        y = ty0,
        yend = ty0 + MARK_LEN,
        colour = "white",
        linewidth = 0.25,
        alpha = 0.7
      )
  }

  p <- p +
    coord_fixed(xlim = xlim, ylim = c(0, FIELD_WIDTH), expand = FALSE) +
    theme_void()

  if (!is.null(los_x)) {
    p <- p +
      annotate(
        "segment",
        x = los_x,
        xend = los_x,
        y = 0,
        yend = FIELD_WIDTH,
        colour = "#1f4fd8",
        linewidth = 0.9
      )
    if (!is.null(yards_to_go)) {
      p <- p +
        annotate(
          "segment",
          x = los_x + yards_to_go,
          xend = los_x + yards_to_go,
          y = 0,
          yend = FIELD_WIDTH,
          colour = "#f5c518",
          linewidth = 0.9
        )
    }
  }

  p
}

# ---- marker styling ---------------------------------------------------

#' Precompute per-row marker and label colours
#'
#' Both the marker outline and the jersey text use scale_colour_identity(),
#' so the values are computed here rather than mapped through a scale.
#' Outline encodes offense/defense, which team colours alone would lose.
style_players <- function(players, pal, outline_side = TRUE) {
  players |>
    mutate(
      .txt_col = label_colour(unname(pal[team_abbr])),
      .out_col = if (outline_side) {
        if_else(side == "offense", "white", "grey15")
      } else {
        "white"
      }
    )
}

# ---- static frame -----------------------------------------------------

#' One frame: players as jersey-numbered discs, ball as a small point
#'
#' @param pal Optional named palette from team_fill_palette(). Supply it
#'   explicitly when rendering multiple frames so colours stay fixed.
plot_frame <- function(
  frame_df,
  los_x = NULL,
  yards_to_go = NULL,
  pal = NULL,
  outline_side = TRUE,
  hash_marks = TRUE
) {
  players <- filter(frame_df, !is_ball)
  ball <- filter(frame_df, is_ball)

  pal <- resolve_palette(players, pal)
  players <- style_players(players, pal, outline_side)

  gg_field(los_x, yards_to_go, hash_marks = hash_marks) +
    geom_point(
      data = players,
      aes(x, y, fill = team_abbr, colour = .out_col),
      shape = 21,
      size = 5.5,
      stroke = 0.7
    ) +
    geom_text(
      data = players,
      aes(x, y, label = jersey_number, colour = .txt_col),
      size = 2.1,
      fontface = "bold",
      show.legend = FALSE
    ) +
    geom_point(
      data = ball,
      aes(x, y),
      shape = 21,
      size = 2.6,
      fill = "#7a4a1f",
      colour = "white"
    ) +
    scale_fill_manual(values = pal, name = NULL) +
    scale_colour_identity() +
    theme(legend.position = "bottom")
}

# ---- animation --------------------------------------------------------

#' Velocity components from speed and direction
#'
#' dir is degrees clockwise from +y: dir = 0 -> +y, dir = 90 -> +x. This
#' is the convention validated by the frame-to-frame displacement check
#' in notes/decisions.md.
velocity_xy <- function(s, dir) {
  rad <- dir * pi / 180
  list(vx = s * sin(rad), vy = s * cos(rad))
}

#' Build a gganimate object for one play
#'
#' @param show_velocity Draw velocity vectors scaled to 0.5s of travel.
#'   These are a useful sanity check: arrows come from s/dir while the
#'   visible motion comes from x/y, so a bad angle convention shows up
#'   as arrows that trail, lead, or sit perpendicular to the movement.
#' @param pad Yards of margin around the action in x.
animate_play <- function(
  play_trk,
  this_play,
  show_velocity = TRUE,
  pad = 6,
  pal = NULL,
  outline_side = TRUE,
  hash_marks = TRUE
) {
  snap_frame <- play_trk$frame_id[which(play_trk$event == "ball_snap")][1]
  if (is.na(snap_frame)) {
    snap_frame <- min(play_trk$frame_id)
  }

  df <- play_trk |>
    mutate(
      t_rel = (frame_id - snap_frame) / TRACKING_HZ,
      vx = velocity_xy(s, dir)$vx,
      vy = velocity_xy(s, dir)$vy
    )

  xr <- range(df$x, na.rm = TRUE)
  xlim <- c(max(0, xr[1] - pad), min(FIELD_LENGTH, xr[2] + pad))

  players <- filter(df, !is_ball)
  ball <- filter(df, is_ball)

  pal <- resolve_palette(players, pal)
  players <- style_players(players, pal, outline_side)

  p <- gg_field(
    los_x = this_play$los_x,
    yards_to_go = this_play$yards_to_go,
    xlim = xlim,
    hash_marks = hash_marks
  )

  if (show_velocity) {
    p <- p +
      geom_segment(
        data = players,
        aes(x = x, y = y, xend = x + vx * 0.5, yend = y + vy * 0.5),
        colour = "white",
        alpha = 0.75,
        linewidth = 0.4,
        arrow = arrow(length = unit(0.05, "cm"))
      )
  }

  p +
    geom_point(
      data = players,
      aes(x, y, fill = team_abbr, colour = .out_col),
      shape = 21,
      size = 6,
      stroke = 0.7
    ) +
    geom_text(
      data = players,
      aes(x, y, label = jersey_number, colour = .txt_col),
      size = 2.2,
      fontface = "bold",
      show.legend = FALSE
    ) +
    geom_point(
      data = ball,
      aes(x, y),
      shape = 21,
      size = 3,
      fill = "#7a4a1f",
      colour = "white"
    ) +
    scale_fill_manual(values = pal, name = NULL) +
    scale_colour_identity() +
    labs(subtitle = "t = {sprintf('%+.1f', frame_time)}s from snap") +
    theme(
      legend.position = "bottom",
      plot.title = element_text(size = 9),
      plot.subtitle = element_text(size = 8, family = "mono")
    ) +
    transition_time(t_rel) +
    ease_aes("linear")
}

#' Render a play to disk at real-time speed
#'
#' Sets nframes to the actual frame count and fps to the capture rate, so
#' there's one animation frame per tracking frame and no interpolation.
#' gganimate's default of 100 frames tweens the motion, which looks
#' subtly wrong.
#'
#' Defaults to GIF via gifski. GIFs are larger than mp4 for the same
#' clip, but they embed in Quarto/reveal.js output with a plain <img> tag
#' and loop on their own — no video element, no autoplay policy to fight.
#'
#' @param path Output file. An extensionless path gets .gif appended;
#'   pass .mp4 explicitly to render video via av instead.
render_play <- function(
  play_trk,
  this_play,
  path,
  width = 900,
  height = 500,
  ...
) {
  anim <- animate_play(play_trk, this_play, ...) +
    labs(title = this_play$play_description)

  ext <- tolower(tools::file_ext(path))
  if (ext == "") {
    path <- paste0(path, ".gif")
    ext <- "gif"
  }

  renderer <- switch(
    ext,
    gif = gifski_renderer(path),
    mp4 = av_renderer(path),
    stop(
      "Unsupported output extension: .",
      ext,
      ". Use .gif (default) or .mp4.",
      call. = FALSE
    )
  )

  animate(
    anim,
    nframes = n_distinct(play_trk$frame_id),
    fps = TRACKING_HZ,
    width = width,
    height = height,
    renderer = renderer
  )
}
