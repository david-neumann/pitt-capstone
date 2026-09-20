# Decisions log

NFL Big Data Bowl 2021 (2018 season) — STAT 1961 capstone.

This log is the source for the Methods section of the December report. Every
entry is a decision, not a finding: something that could reasonably have gone
another way, with the counts attached and the cost stated. Findings that
constrain decisions are recorded under **Verified assumptions** and **Structural
constraints**.

Counts current as of the week-4 rebuild unless marked otherwise.

---

## 0. Pipeline structure

**Decision.** Split the pipeline into four scripts with a strict ownership
boundary, replacing a two-script build in which the analytical sample was
written as a side effect of rendering `analysis/01_eda.qmd`.

| Script | Owns |
|---|---|
| `01_raw_to_parquet.R` | CSV → Parquet mirror of the Kaggle download. No transformation. |
| `02_build_canonical.R` | Naming, deduplication, `side`/`is_ball`/`team_abbr`, coordinate standardization, key types. Drops no plays. |
| `03_build_play_index.R` | Measured facts, one row per play and per player-play. No decisions. |
| `04_build_sample.R` | Exclusion decisions, via `R/sample_rules.R`. |

`analysis/01_eda.qmd` reads and reports; it writes nothing.

**Rationale.** The sample definition previously depended on intermediate objects
(`defects`, `per_play`, `play_timeline`, `ball_check`) that existed only inside a
notebook render, so it could not be re-run, inspected, or changed without
re-rendering a document.

**Test used to place a column.** A column answering *"what is true of this
play"* belongs in `play_index`; a column answering *"should this play be kept"*
is a decision and belongs in `sample_flags`. `has_kinematic_defect` is the first
kind, `keep_clean_window` the second.

**Cost.** Four build steps instead of two, and one additional Parquet layer
(`play_index`, `player_play_index`, `play_events`, `kinematic_defects`).

---

## 1. Cleaning

**Duplicate raw rows.** The raw week files contain exactly-duplicated player
rows. `02_build_canonical.R` removes them with a full-row `distinct()` and then
asserts on the key `(game_id, play_id, nfl_id, frame_id)`, because a
*conflicting* duplicate would survive `distinct()` and double-weight a player in
every per-frame aggregate.

| Week | Rows in | Rows out | Removed |
|---|---|---|---|
| 2 | 1,231,793 | 1,230,925 | 868 |
| 14 | 1,161,644 | 1,160,264 | 1,380 |
| 17 | 1,049,265 | 1,047,744 | 1,521 |
| **Total** | | | **3,769** |

The affected rows are concentrated in exactly 3 plays and were confirmed
byte-identical. Row counts are persisted to `data/processed/dedup_log.parquet`.

Deduplication happens in `02`, not `01`, so the interim layer stays a faithful
copy of the source CSVs and the decision is reversible.

**The "internal frame gaps" finding was an artifact.** The gaps reported on the
pre-deduplication build *were* that duplication. The `gapless` test compares a
player's row count to their frame span, so doubled rows fail it exactly as
missing rows do. Post-deduplication, a non-gapless player-play means a genuine
mid-play dropout.

**Per-week deduplication is scoped per week**, so a play appearing in two week
files would pass both the `distinct()` and the per-week key assertion.
`02_build_canonical.R` now also checks play-key uniqueness across all 17 weeks
after the loop.

**Key types.** Every identifier in `data/processed/` is cast to `int32` via
`cast_keys()` in `R/utils.R`. Arrow stores these as `int64`; collecting into R
yields `integer64` or `double` depending on whether `bit64` is attached, and a
type mismatch on a join key produces **zero matches rather than an error**.
`gameId` (e.g. 2018090600) fits inside the `int32` ceiling.

**`event == "None"` recoded to `NA`.** The source encodes "no event this frame"
as the string `"None"`.

---

## 2. Verified assumptions

These were assumptions in code comments. Testing them makes them results.

**`dir` is degrees clockwise from $+y$.** Confirmed against frame-to-frame
displacement on a random sample of 300 plays (`set.seed(1961)`). Measuring from
$+y$ gives a median error at the rounding scale of the source data; measuring
from $+x$ — the plausible alternative — gives a median error at the step length
itself ($\approx 0.28$ yd), because the wrong convention reflects the predicted
step about the $45°$ line. The margin is decisive, not marginal. Hence

$$v_x = s\sin(\text{dir}\cdot\pi/180), \qquad v_y = s\cos(\text{dir}\cdot\pi/180)$$

The same test puts $|\text{displacement} - \texttt{dis}|$ at $\approx 0.01$ yd,
which rules out a coordinate-transform bug simultaneously.

**`standardize_direction()` is a rotation, not a reflection.** It reflects
*both* $x$ and $y$ and shifts `dir` and `o` by $180°$. Flipping only $x$ would
mirror the field, swapping offensive left and right while producing entirely
plausible-looking output. Verified by ECDFs of offensive snap positions split by
original `play_direction`: the curves coincide on both axes.

Quantiles are compared rather than a test statistic. At $n \approx 10^5$ per
group a two-sample KS test rejects on differences far too small to matter, so
the $p$-value carries no information.

The function now errors on a missing `play_direction` rather than propagating
`NA` into `x`, `y`, `dir`, `o` for that play.

**`possessionTeam` is never mislabeled.** All 23 zero-offense plays are genuine
tracking gaps. The `side`-derivation fallthrough hypothesis — that an `NA` in
`team_abbr` or `possession_team` would silently label a row `"defense"` — was
rejected by three checks: `team_abbr` has no missing values among player rows,
the abbreviation vocabularies of `plays` and `games` agree exactly, and every
suspect play's `possession_team` matches one of its own two teams. The
discriminating test was geometric: every suspect play has no quarterback and its
tracked players sit downfield of the LOS, so the tracked group is genuinely the
defense.

The explicit `NA` branch and assertion in the derivation are defensive only.
They convert a silent failure mode into a loud one for future rebuilds.

**Join integrity.** Five checks return zero in both directions:
tracking ↔ `players`, tracking ↔ `plays`, tracking → `games`. These are now
assertions in `03_build_play_index.R` rather than a table in the notebook.

---

## 3. Structural constraints

Not decisions — facts that bound what questions are askable.

**Only 13 players are tracked per play.** Offensive and defensive linemen are
excluded. This rules out any analysis of pass rush, blocking, or pocket
integrity. Observed mean is $263{,}173 / 19{,}239 \approx 13.7$ tracked players
per play, the excess coming from goal-line packages and the exceptions below.

**The pre-snap window is fixed at 10 frames — exactly $1.0$ s — on over 99% of
plays.** `p05`, `p50`, and `p95` of `frames_pre_snap` coincide, so this is a
structural constant rather than a distribution. Every pre-snap feature
(alignment, leverage, motion detection) has $1.0$ s and no more, and no amount
of filtering buys extra.

**Coverage labels exist for week 1 only.** This is the binding constraint on any
coverage-framed question and the reason for the fork in §6.

**Kinematic defects cluster by week.** 1,396 defective rows total. The
clustering is a collection artifact rather than noise, which is what justifies
treating them as a data-quality exclusion rather than modeling them.

---

## 4. Sample definition

### 4.1 Rejected: filtering on `n_players`

Filtering on the number of tracked players would select on **defensive scheme**
rather than on data quality — a light-box package and a tracking failure both
present as a low count. Every filter is instead tied to a *named defect*.

### 4.2 Adopted: the scoped kinematic rule

A play is excluded only when a defective row falls **between the snap and the
throw**. A whole-play rule discards a 60-frame play for one bad frame, and the
majority of defective rows land after the throw, outside any interval that feeds
a separation or timing measurement.

**Cost, stated for Methods:** retained plays may contain uncleaned frames
outside the measurement window. `has_kinematic_defect` and `defect_in_window`
travel with `analytic_sample.parquet`, so a model can test sensitivity to this
choice without rebuilding the funnel. The conservative (whole-play) rule is
retained in `R/sample_rules.R` and reported alongside solely to quantify the
difference.

Thresholds live in `R/constants.R`: `MAX_SPEED = 13` yd/s (elite human top speed
is about $10.5$), `MAX_DIS = MAX_SPEED / 10` yd per frame, `MAX_ACCEL = 20`
yd/s². Angles must lie in $[0, 360)$. These moved out of the notebook because
`03` flags rows with them, and a threshold differing between script and notebook
would make the two disagree about which plays are clean. Recoverable: raw `s`,
`a`, `dis` remain in the tracking layer and the defect table rebuilds from
scratch on every run.

### 4.3 Adopted: `pass_shovel` as an alternate throw anchor

Some recorded completions and incompletions carry no `pass_forward` event; the
throw is labeled differently. A `pass_forward`-only anchor discards real passes
as though they were sacks. `keep_any_throw` accepts either.

`analytic_sample.parquet` carries `f_throw = coalesce(f_pass_forward,
f_pass_shovel)` and `throw_anchor`, so the precedence is resolved once, in the
same place the rule accepted it, and no downstream file re-derives it.

### 4.4 Adopted: population filters ordered before quality filters

Flags are split into two blocks. **Population** filters define what is in scope
(`keep_live_play`, `keep_snap`, `keep_any_throw`). **Quality** filters identify
in-scope plays that cannot be measured (`keep_los`, `keep_sides`, `keep_ball`,
`keep_no_dupes`, `keep_clean_window`).

Conjunction is order-independent, so the surviving count is identical under any
ordering. What the ordering buys is interpretability: each quality step's
`dropped` reads as "plays I wanted but cannot use" rather than being inflated by
plays that were never in scope.

Both conditional (funnel) and marginal (unconditional) counts are reported,
because they answer different questions and are easy to conflate. The
missing-LOS *block* is about 639 plays; the number the funnel *attributes* to
`keep_los` is smaller, because some of those plays were already out on
population grounds.

### 4.5 Funnel

Final sample: **17,081 of 19,239 plays (88.8%), all 17 weeks.**

> **Counts below are from the week-4 run, which applied quality filters before
> population filters.** The final count is unchanged by the reordering in §4.4,
> but the per-step `dropped` values in the quality block will decrease and
> `keep_any_throw` will increase. Refresh this table from
> `data/processed/sample_funnel.parquet` after the next build.

| Step | Group | Dropped | Remaining |
|---|---|---|---|
| all plays | — | — | 19,239 |
| has `offense_formation` | population | 141 | 19,098 |
| has a line of scrimmage | quality | 592 | 18,506 |
| ≥5 players tracked per side | quality | 34 | 18,472 |
| ball tracked every frame | quality | 17 | 18,455 |
| no duplicate rows | quality | 0 | 18,455 |
| no defect snap→throw | quality | 118 | 18,337 |
| has `ball_snap` | population | 0 | 18,337 |
| has a throw event | population | 1,256 | 17,081 |

Two observations for Methods:

1. **Four filters are effectively assertions, not filters.** `keep_sides` (34),
   `keep_ball` (17), `keep_no_dupes` (0), and `keep_snap` (0) together remove 51
   plays — $0.3\%$. Data-quality attrition is negligible except for `keep_los`.
2. **`keep_no_dupes` is a tripwire.** It drops zero plays because `02`
   deduplicates upstream. A nonzero count means the cleaning step regressed.

### 4.6 `keep_any_throw` is a population definition, not attrition

Composition of the no-throw block (conditional on `keep_live_play` and
`keep_snap`):

| `pass_result` | n |
|---|---|
| S (sack) | 1,299 |
| IN (interception) | 2 |
| `NA` | 2 |
| I (incomplete) | 1 |
| R (scramble) | 1 |
| **Total** | **1,305** |

1,299 sacks is consistent with league-wide 2018 totals, so this filter defines
the population — plays on which a forward pass was released — rather than
discarding usable data. The **six-play residual** is the entire event-labeling
gap: recorded pass attempts with no throw event of any kind, either
penalty-nullified or mislabeled. They stay out.

(1,305 here vs 1,256 in the funnel: 49 of these plays were already removed by
quality filters running ahead of `keep_any_throw` under the week-4 ordering.)

### 4.7 The missing-LOS block is not missing-at-random

`absolute_yardline_number`, `los_x`, `game_clock`, `type_dropback`, and both
pre-snap score columns are missing on an identical count of plays — one coherent
block of play-level metadata, roughly 639 plays, not six independent gaps.

The block runs **≈72% incomplete against a ≈31% baseline.**

**This is the only non-ignorable exclusion in the pipeline.** It accounts for
roughly a quarter of all attrition and it is selected on outcome. Any outcome
model fit on the retained sample carries that selection, and the Methods section
must state its direction and magnitude rather than reporting the exclusion as
routine.

A related check: the thrown-pass subset of zero-route plays is enriched in
incompletions at a similar rate. Whether these are one block or two is tested in
notebook §3.6 (`route-los-overlap`); if `keep_los` already removes them, no
separate exclusion is needed.

---

## 5. Coverage labels

**Eight labels collapse to a man/zone binary.** The eight-class cells have a
minimum of one play and cannot support an eight-class model.

**`Prevent Zone` maps to `NA`, not to zone.** A single garbage-time play. It
describes game *state*, not scheme, so it drops out of any
coverage-conditional sample rather than contaminating the zone class.

**The collapse lives in `classify_coverage()` in `R/coverage.R`, applied at the
sample layer.** It was previously computed inside `02_build_canonical.R`, which
put a modeling decision in the data layer.
`data/processed/coverages_week1.parquet` carries the original eight-label
`coverage` column verbatim, so a multi-class framing remains available without a
rebuild.

**Precedence is explicit:** `Man` is tested before `Zone`, so a hypothetical
label containing both words classifies as man. No label in the 2018 week-1
vocabulary contains both, but the rule should not be implicit in `case_when()`
ordering.

**`02` asserts the vocabulary.** Any label that falls through the mapping other
than the one deliberate exclusion raises a build-time error rather than a silent
`NA` at model-fit time.

**Descriptive only.** The observed completion-rate difference between man and
zone is confounded by down, distance, field position, and personnel. Any claim
about coverage effect requires conditioning on all of them.

---

## 6. Open items

**The research question fork.** Q1 (expected separation at the throw) and Q2
(completion probability as defender credit) share a pipeline and sample. Q3
(man/zone classification) is the structural fork, potentially as a label
generator for Q1/Q2 at full sample size.

The tradeoff is stated in notebook §4.3: coarse man/zone coverage on the single
labeled week, or drop coverage as a covariate and use the full-season sample.
Week 5 is the de facto scope commitment deadline.

**Play types measurable but not yet filtered.** `SAMPLE_RULE` is
question-agnostic by design: it removes plays that are not live, not pass
attempts, or not measurable. It does **not** remove play types that are
measurable but may be inappropriate for a given question. Currently retained:

- QB spikes (clock management, no intended receiver)
- Throwaways (real throw, no receiver targeted)
- Screens (separation dynamics differ)
- Penalty-nullified plays (real tracking, no official play)
- Batted or tipped passes at the line (outcome set before separation matters)
- Hail Marys (coverage geometry unrelated to the usual model)
- Goal-line plays with extra linemen
- Two-point conversions, if present

Intended approach: flag these in `sample_flags` **without filtering**, so each
candidate question selects its own population on top of a shared base.
Identification is via the nflverse play-by-play join (`gameId` →
`old_game_id`), which supplies `qb_spike`, `qb_scramble`, `penalty`,
`two_point_attempt`, and `aborted_play`. Deferred until the question is settled.

**No modeling features exist yet.** The complete set of derived columns is
`los_x`, `defense_team`, `is_ball`, `team_abbr`, `side`, standardized
`x`/`y`/`dir`/`o`, and the event-frame and count columns in `play_index`. There
is no per-frame time index relative to the snap, no pairwise distance, no
nearest-defender assignment, and no route-shape summary. The first
feature-engineering step is unwritten and will almost certainly need a
snap-relative frame index joined onto tracking.

---

## 7. Known technical constraints

- Arrow `Dataset` objects do not survive knitr cache serialization. Caching must
  stay disabled in any notebook holding a lazy Arrow dataset.
- Quarto's default `execute-dir: file` starts the kernel in the notebook's
  subdirectory, which prevents `.Rprofile` from loading and renv from
  activating. Fixed via `execute-dir: project` in `_quarto.yml`.
- Helper files in `R/` define functions; they do not attach packages.
  `library()` calls belong in notebooks and scripts. (`R/viz.R` is the remaining
  exception.)
- Chunk labels prefixed `fig-` trigger Quarto's cross-referencing system and
  produce unwanted "Figure" captions. Avoid the prefix.
- Arrow will not push down `lag()`, so frame-to-frame differencing runs on a
  collected sample rather than the full dataset.
- Arrow's `quantile()` is a t-digest approximation and is the wrong tool for
  extreme-tail work. Tail quantiles are computed from exact bin counts; extrema
  from a separate scalar aggregate.
