## 2026-09-03 — Data foundation

- **Dataset**: BDB 2021 (2018 season, passing plays). 18,309,388 tracking rows, 19,239 plays.
- **Only 13 players tracked per play**, not 22. No OL or DL in the data — confirmed by position counts and by personnel arithmetic (e.g. "2 RB, 1 TE, 2 WR" + QB = 6 offense; "4 DL, 2 LB, 5 DB" → 7 tracked defense). Rules out any question about pass rush, blocking, or pocket integrity. Rows-per-frame varies with personnel grouping.
- **`team` in tracking is home/away/football**, not an abbreviation. Offense/defense derived in canonical layer by joining games for home/away abbrs and comparing to plays\$possession_team. Not to be re-derived downstream.
- **Standardized play direction by 180° rotation** (reflect both x and y, shift dir/o by 180). Validated against frame-to-frame displacement: median disagreement 0.83°, p90 2.6°, p99 12.1°. Tail attributable to coordinate rounding and mid-frame direction changes.
- Kept `play_direction` in the canonical output as an audit trail.
