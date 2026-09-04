library(ggplot2)
library(gganimate)

#' Empty standardized field. Offense always advances toward +x.
gg_field <- function(los_x = NULL, yards_to_go = NULL, xlim = c(0, 120)) {
  yard_lines <- seq(10, 110, by = 5)

  p <- ggplot() +
    annotate(
      "rect",
      xmin = 0,
      xmax = 120,
      ymin = 0,
      ymax = 160 / 3,
      fill = "#4a7c47"
    ) +
    annotate(
      "rect",
      xmin = 0,
      xmax = 10,
      ymin = 0,
      ymax = 160 / 3,
      fill = "#3a6337"
    ) +
    annotate(
      "rect",
      xmin = 110,
      xmax = 120,
      ymin = 0,
      ymax = 160 / 3,
      fill = "#3a6337"
    ) +
    annotate(
      "segment",
      x = yard_lines,
      xend = yard_lines,
      y = 0,
      yend = 160 / 3,
      colour = "white",
      linewidth = 0.3,
      alpha = 0.6
    ) +
    coord_fixed(xlim = xlim, ylim = c(0, 160 / 3), expand = FALSE) +
    theme_void()

  if (!is.null(los_x)) {
    p <- p +
      annotate(
        "segment",
        x = los_x,
        xend = los_x,
        y = 0,
        yend = 160 / 3,
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
          yend = 160 / 3,
          colour = "#f5c518",
          linewidth = 0.9
        )
    }
  }
  p
}

#' One frame: players as jersey-numbered discs, ball as a small point.
plot_frame <- function(frame_df, los_x = NULL, yards_to_go = NULL) {
  players <- dplyr::filter(frame_df, !is_ball)
  ball <- dplyr::filter(frame_df, is_ball)

  gg_field(los_x, yards_to_go) +
    geom_point(
      data = players,
      aes(x, y, fill = side),
      shape = 21,
      size = 5.5,
      colour = "white",
      stroke = 0.7
    ) +
    geom_text(
      data = players,
      aes(x, y, label = jersey_number),
      size = 2.1,
      colour = "white",
      fontface = "bold"
    ) +
    geom_point(
      data = ball,
      aes(x, y),
      shape = 21,
      size = 2.6,
      fill = "#7a4a1f",
      colour = "white"
    ) +
    scale_fill_manual(
      values = c(offense = "#c8102e", defense = "#0b2265"),
      name = NULL
    ) +
    theme(legend.position = "bottom")
}

#' Convert speed + direction into velocity components
#'
#' dir is degrees clockwise from +y, which is the convention the
#' displacement check in standardize.R validated. Inverting it:
#' dir = 0 -> +y, dir = 90 -> +x.
velocity_xy <- function(s, dir) {
  rad <- dir * pi / 180
  list(vx = s * sin(rad), vy = s * cos(rad))
}

#' Animate a single play
#'
#' @param play_trk canonical tracking rows for one play
#' @param this_play the matching single row from plays.parquet
#' @param show_velocity draw velocity vectors scaled to 0.5s of travel
#' @param pad yards of margin around the action in x
animate_play <- function(play_trk, this_play, show_velocity = TRUE, pad = 6) {
  snap_frame <- play_trk$frame_id[play_trk$event == "ball_snap"][1]
  if (is.na(snap_frame)) {
    snap_frame <- min(play_trk$frame_id)
  }

  df <- play_trk |>
    dplyr::mutate(
      t_rel = (frame_id - snap_frame) / 10, # tracking is 10 Hz
      vx = velocity_xy(s, dir)$vx,
      vy = velocity_xy(s, dir)$vy
    )

  xr <- range(df$x, na.rm = TRUE)
  xlim <- c(max(0, xr[1] - pad), min(120, xr[2] + pad))

  players <- dplyr::filter(df, !is_ball)
  ball <- dplyr::filter(df, is_ball)

  p <- gg_field(
    los_x = this_play$los_x,
    yards_to_go = this_play$yards_to_go,
    xlim = xlim
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
      aes(x, y, fill = side),
      shape = 21,
      size = 6,
      colour = "white",
      stroke = 0.7
    ) +
    geom_text(
      data = players,
      aes(x, y, label = jersey_number),
      size = 2.2,
      colour = "white",
      fontface = "bold"
    ) +
    geom_point(
      data = ball,
      aes(x, y),
      shape = 21,
      size = 3,
      fill = "#7a4a1f",
      colour = "white"
    ) +
    scale_fill_manual(
      values = c(offense = "#c8102e", defense = "#0b2265"),
      name = NULL
    ) +
    labs(subtitle = "t = {sprintf('%+.1f', frame_time)}s from snap") +
    theme(
      legend.position = "bottom",
      plot.title = element_text(size = 9),
      plot.subtitle = element_text(size = 8, family = "mono")
    ) +
    transition_time(t_rel) +
    ease_aes("linear")
}
