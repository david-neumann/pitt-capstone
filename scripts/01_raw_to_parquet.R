# scripts/01_raw_to_parquet.R ------------------------------------------
# raw -> interim. Converts the Kaggle CSVs to Parquet without modifying
# their contents, so later steps never re-read CSV.
#
# Outputs, in data/interim/:
#   games, players, plays, targetedReceiver, coverages_week1 (.parquet)
#   tracking/week_NN.parquet  one file per week, with a `week` column

library(readr)
library(dplyr)
library(arrow)
library(fs)
library(here)

raw_dir <- here("data", "raw")
interim_dir <- here("data", "interim")
tracking_dir <- path(interim_dir, "tracking")

dir_create(tracking_dir)

# --- Metadata tables ---
for (file in c(
  "games",
  "players",
  "plays",
  "targetedReceiver",
  "coverages_week1"
)) {
  message("Converting ", file)
  read_csv(path(raw_dir, paste0(file, ".csv")), show_col_types = FALSE) |>
    write_parquet(path(interim_dir, paste0(file, ".parquet")))
}

# --- Tracking tables ---
for (w in 1:17) {
  message("Converting week ", w)
  read_csv(
    path(raw_dir, paste0("week", w, ".csv")),
    show_col_types = FALSE,
    progress = FALSE
  ) |>
    mutate(week = w) |>
    write_parquet(path(tracking_dir, sprintf("week_%02d.parquet", w)))
  gc()
}

message("Done.")
