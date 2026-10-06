# Decisions log

NFL Big Data Bowl 2021 (2018 season) — STAT 1961 capstone.

This log is the source for the Methods section of the December report. Every
entry is a decision, not a finding: something that could reasonably have gone
another way, with the counts attached and the cost stated. Findings that
constrain decisions are recorded under **Verified assumptions** and **Structural
constraints**.

Counts were re-verified against the build in place on 2026-10-04 (sample rule
with population filters ordered first, §4.4; nflverse pull of 2025-04-30, §8.1)
unless marked otherwise.

Section numbers are cited from code comments and notebooks (§4.2, §4.6–§4.8,
§5, §6, §6.1, §7, §8.2, §8.3, §8.6). Do not renumber them without updating the
citations.

---

## 0. Pipeline structure

**Decision.** Split the pipeline into build scripts with a strict ownership
boundary, replacing a two-script build in which the analytical sample was
written as a side effect of rendering `analysis/01_eda.qmd`.

| Script | Status | Owns |
|---|---|---|
| `01_raw_to_parquet.R` | built | CSV → Parquet mirror of the Kaggle download. No transformation. |
| `02_build_canonical.R` | built | Naming, deduplication, `side`/`is_ball`/`team_abbr`, coordinate standardization, key types. Drops no plays. |
| `03_build_play_index.R` | built | Measured facts, one row per play and per player-play. No decisions. |
| `04_build_sample.R` | built | Base sample exclusions, via `R/sample_rules.R`. |
| `05_join_pbp.R` | built | Pulls and mirrors nflverse play-by-play; emits `pbp.parquet` on the plays keys. Measured facts only. |
| `06_build_throw_frame.R` | built | Applies `R/arrival.R` at season scale; emits `arrival.parquet`, `approach.parquet`, and the throw-frame slice `throw_frame.parquet` (§6.9). Measured facts only; no outcome columns. |
| `07_build_features.R` | built | Throw-frame coverage features; emits `features.parquet`: separation and closing speed (stage 3, §9.8); leverage, time to arrival, and the passing window (stage 4, §9.9). |
| `08_build_model_frame.R` | built | Applies `QUESTION_RULE` on top of the analytic sample, prepares predictors, asserts completeness and the absence of leak columns; emits `model_frame.parquet` and `model_funnel.parquet` (§9.1). |
| `09_fit_models.R` | built | Fits every stage in `MODEL_SPECS` once; emits `oof_preds.parquet`, `oof_specs.parquet`, and `models/full_fits.rds` (§9.4). |

| Helper / notebook | Owns |
|---|---|
| `R/geometry.R` | Componentwise vector geometry. Functions only, no grouping. |
| `R/arrival.R` | Kinematic arrival detection — a grouped sequence reduction, so it does not fit `geometry.R`'s contract. |
| `R/pbp.R` | The nflverse bridge: key casts, column vocabulary, leak assertion, join-validation functions. No network access. |
| `R/evaluate.R` | Model frame preparation, model specs, cross-validation harness, scoring (§9). |
| `analysis/01_eda.qmd` | Data audit and sample-definition report. Writes nothing. |
| `analysis/02_arrival_anchor.qmd` | Arrival-anchor investigation. Writes nothing. |
| `analysis/03_model_baseline.qmd` | Models, scoring, calibration, and the `cp` benchmark, on `model_frame.parquet` and the fits from `09`. Writes nothing to `data/`. |
| `analysis/04_arrival_season.qmd` | Season-scale validation of the arrival anchor (§6.9). Writes nothing. |
| `analysis/05_robustness.qmd` | Robustness of the stage comparisons (§9.11); the baseline is read from `09`. Writes nothing to `data/`. |

`R/arrival.R` exists as a helper rather than living inside `06` because the
notebook is a second caller, and duplicated measurement logic goes stale. The
same reasoning moved `require_cols()` out of `02_build_canonical.R` into
`R/utils.R` once `05` became a second caller.

**Test used to place a column.** A column answering *"what is true of this
play"* belongs in `play_index` or `pbp.parquet`; a column answering *"should
this play be kept"* is a decision and belongs in `R/sample_rules.R`.
`has_kinematic_defect` is the first kind, `keep_clean_window` the second.

**Two funnels.** `04` applies the question-agnostic base rule (§4) and writes
`analytic_sample.parquet`. Question-level population filters (§4.9, the
beyond-the-LOS threshold in §7) are defined as flags in `R/sample_rules.R`,
applied by `08`, and reported as a second funnel. `05` makes no exclusions.

**Cost.** More build steps, and additional Parquet layers (`play_index`,
`player_play_index`, `play_events`, `kinematic_defects`, `pbp`).

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
The canonical tracking build has 18,305,619 rows.

Deduplication happens in `02`, not `01`, so the interim layer stays a faithful
copy of the source CSVs and the decision is reversible.

**The "internal frame gaps" finding was an artifact.** The gaps reported on the
pre-deduplication build *were* that duplication. The `gapless` test compares a
player's row count to their frame span, so doubled rows fail it exactly as
missing rows do. Post-deduplication, a non-gapless player-play means a genuine
mid-play dropout.

**Deduplication is per week**, so a play appearing in two week files would pass
both the `distinct()` and the per-week key assertion. `02` also checks play-key
uniqueness across all 17 weeks after the loop.

**Key types.** Every identifier in `data/processed/` is cast to `int32` via
`cast_keys()` in `R/utils.R`. Arrow stores these as `int64`; collecting into R
yields `integer64` or `double` depending on whether `bit64` is attached, and a
type mismatch on a join key produces **zero matches rather than an error**.
`gameId` (e.g. 2018090600) fits inside the `int32` ceiling. The same cast is
what makes the nflverse bridge work (§8.1), where `old_game_id` arrives as
character and `play_id` as double.

**`event == "None"` recoded to `NA`.** The source encodes "no event this frame"
as the string `"None"`.

---

## 2. Verified assumptions

These were assumptions in code comments. Testing them makes them results.

**`dir` is degrees clockwise from $+y$.** Confirmed against frame-to-frame
displacement on a random sample of 300 plays (`set.seed(1961)`,
`analysis/01_eda.qmd` §2.6). Measuring from $+y$ gives a median error at the
rounding scale of the source data; measuring from $+x$ — the plausible
alternative — gives a median error at the step length itself
($\approx 0.28$ yd), because the wrong convention reflects the predicted step
about the $45°$ line. Hence

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

The function errors on a missing `play_direction` rather than propagating `NA`
into `x`, `y`, `dir`, `o` for that play.

**`possessionTeam` is never mislabeled.** All 23 zero-offense plays are genuine
tracking gaps. The hypothesis that an `NA` in `team_abbr` or `possession_team`
would silently label a row `"defense"` was rejected by three checks: `team_abbr`
has no missing values among player rows, the abbreviation vocabularies of
`plays` and `games` agree exactly, and every suspect play's `possession_team`
matches one of its own two teams. The discriminating test was geometric: every
suspect play has no quarterback and its tracked players sit downfield of the
LOS, so the tracked group is genuinely the defense.

The explicit `NA` branch and assertion in the derivation are defensive only.

**Join integrity.** Tracking ↔ `players`, tracking ↔ `plays`, and tracking →
`games` return zero mismatches in every direction. These are assertions in
`03_build_play_index.R`. The nflverse join is verified separately and on
different grounds (§8.2), because a key-level check cannot detect keys matched
to the wrong plays.

**Ball kinematics are populated.** `s` and `dis` on ball rows are each missing on
exactly 1 of 1,247,642 rows. The kinematic defect scan in `03` filters
`!is_ball`, so ball rows are never flagged. Ball `dis` is the discriminating
column in §6.

---

## 3. Structural constraints

Not decisions — facts that bound what questions are askable.

**Not all 22 players are tracked per play.** Offensive and defensive linemen are
excluded. This rules out any analysis of pass rush, blocking, or pocket
integrity. Observed mean is $263{,}173 / 19{,}239 \approx 13.7$ tracked players
per play.

**The pre-snap window is fixed at 10 frames — exactly $1.0$ s — on over 99% of
plays.** `p05`, `p50`, and `p95` of `frames_pre_snap` coincide. Every pre-snap
feature (alignment, leverage, motion detection) has $1.0$ s and no more.

**Coverage labels exist for week 1 only.** This is the binding constraint on any
coverage-framed question and the reason coverage classification was scoped out
(§7).

**BDB ships 253 of the season's 256 games, and all three omissions are in week
1.** Established by the game-set comparison against nflverse (§8.1). Week 1 is
therefore **13 games and 1,034 plays**. Games per week otherwise range 13–16
with byes. Consequences:

- The week-1 coverage labels cover 13 games; the shortfall is a data omission,
  not label attrition.
- The arrival-anchor prototyping sample (§6, $n = 890$) is 13 games.

**Kinematic defects cluster by week.** 1,396 defective rows in total. The
clustering is a collection artifact rather than noise, which is what justifies
treating them as a data-quality exclusion rather than modeling them.

**There is no $z$ coordinate.** Ball height is not recorded, so ground contact,
throw trajectory, and contested-catch height are invisible. This is why arrival
has to be inferred from horizontal displacement (§6).

**BDB omits play-level metadata on penalty-nullified plays.** See §4.7.

---

## 4. Sample definition

### 4.1 Rejected: filtering on `n_players`

Filtering on the number of tracked players would select on **defensive scheme**
rather than on data quality — a light-box package and a tracking failure both
present as a low count. Every filter is instead tied to a *named defect*.

### 4.2 Adopted: the scoped kinematic rule

A play is excluded only when a defective row falls **between the snap and the
throw**. A whole-play rule discards a 60-frame play for one bad frame, and most
defective rows fall outside any interval that feeds a separation or timing
measurement:

| Defective rows by position in play | n |
|---|---|
| after the throw | 850 |
| snap to throw | 385 |
| post-snap, no throw | 145 |
| pre-snap | 16 |
| **Total** | **1,396** |

**Cost, stated for Methods:** retained plays may contain uncleaned frames
outside the measurement window. `has_kinematic_defect` and `defect_in_window`
travel with `analytic_sample.parquet`, so a model can test sensitivity without
rebuilding the funnel. The conservative (whole-play) rule is retained in
`R/sample_rules.R` and reported alongside: it keeps **16,533** plays against the
scoped rule's 17,081.

Thresholds live in `R/constants.R`: `MAX_SPEED = 13` yd/s (elite human top speed
is about $10.5$), `MAX_DIS = MAX_SPEED / 10` yd per frame, `MAX_ACCEL = 20`
yd/s². Angles must lie in $[0, 360)$. Recoverable: raw `s`, `a`, `dis` remain in
the tracking layer and the defect table rebuilds on every run of `03`.

`MAX_DIS` has a second, deliberate use in §6 as the ball flight/carry boundary.

### 4.3 Adopted: `pass_shovel` as an alternate throw anchor

Some recorded passes carry no `pass_forward` event; the throw is labeled
differently. A `pass_forward`-only anchor discards real passes as though they
were sacks. `keep_any_throw` accepts either: 1,388 plays fail it against 1,492
failing `keep_throw`, so 104 plays are recovered.

`analytic_sample.parquet` carries `f_throw = coalesce(f_pass_forward,
f_pass_shovel)` and `throw_anchor`, so the precedence is resolved once.

### 4.4 Adopted: population filters ordered before quality filters

Flags are split into two blocks. **Population** filters define what is in scope
(`keep_live_play`, `keep_snap`, `keep_any_throw`). **Quality** filters identify
in-scope plays that cannot be measured (`keep_los`, `keep_sides`, `keep_ball`,
`keep_no_dupes`, `keep_clean_window`).

Conjunction is order-independent, so the surviving count is identical under any
ordering. What the ordering buys is interpretability: each quality step's
`dropped` reads as "plays in scope that cannot be measured".

### 4.5 Funnel

Final sample: **17,081 of 19,239 plays (88.8%), all 17 weeks.** From
`data/processed/sample_funnel.parquet`:

| Step | Group | Dropped | Remaining |
|---|---|---|---|
| all plays | — | — | 19,239 |
| has `offense_formation` | population | 141 | 19,098 |
| has `ball_snap` | population | 0 | 19,098 |
| has a throw event | population | 1,305 | 17,793 |
| has a line of scrimmage | quality | 545 | 17,248 |
| ≥5 players tracked per side | quality | 33 | 17,215 |
| ball tracked every frame | quality | 16 | 17,199 |
| no duplicate rows | quality | 0 | 17,199 |
| no defect snap→throw | quality | 118 | 17,081 |

Marginal (unconditional) failure counts, which answer a different question:
`keep_live_play` 141, `keep_snap` 0, `keep_any_throw` 1,388, `keep_los` 639,
`keep_sides` 36, `keep_ball` 50, `keep_no_dupes` 0, `keep_clean_window` 120.
The missing-LOS block is 639 plays, of which the funnel attributes 545 to
`keep_los` because 94 were already out on population grounds.

Two observations for Methods:

1. **Four filters are effectively assertions.** `keep_snap` (0), `keep_sides`
   (33), `keep_ball` (16), and `keep_no_dupes` (0) together remove 49 plays —
   $0.3\%$. Data-quality attrition is negligible except for `keep_los`.
2. **`keep_no_dupes` is a tripwire.** It drops zero plays because `02`
   deduplicates upstream. A nonzero count means the cleaning step regressed.

The analytic sample holds 17,077 thrown passes (C 11,148, I 5,531, IN 398) and
4 sacks that carry a throw event; the sacks leave at model-frame assembly.

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
gap: recorded pass attempts with no throw event of any kind. They stay out.

### 4.7 The missing-LOS block is the penalty-nullified block, and is selected on outcome

`absolute_yardline_number`, `los_x`, `game_clock`, `type_dropback`, and both
pre-snap score columns are missing on the same **639 plays** — one block of
play-level metadata, not six independent gaps.

**633 of the 639 are penalty-nullified plays** (nflverse `play_type ==
"no_play"`, §8.3): BDB does not carry play-level metadata for a play that was
wiped out. The remaining 6 are 4 completions and 2 incompletions.

The block's 585 thrown passes run **18.3% complete and 79.3% incomplete**,
against 63.4% complete and 34.2% incomplete across all thrown passes on the
spine. Defensive pass interference nullifies incompletions, which is the
mechanism.

**It is a non-ignorable exclusion.** It is selected on outcome, and every
nullified play leaves the sample at `keep_los` — so the question of whether
nullified plays belong in the sample (§8.3) is currently decided by a metadata
gap rather than by argument. The Methods section must state its direction and
magnitude rather than reporting it as routine.

A related check: the thrown-pass subset of zero-route plays is enriched in
incompletions at a similar rate. Whether these are the same block is tested in
`analysis/01_eda.qmd` §3.6 (`route-los-overlap`).

**The pattern, stated once as a working principle.** Selection on outcome is the
central data hazard in this project. Three mechanisms have produced it — the
nullified/missing-metadata block (this section), a candidate measurement rule
(§6.1), and the benchmark's availability, which depends on a named receiver
(§4.9, §8.4) — so any exclusion rule is checked for differential rates by
completion status *before* adoption, not after.

### 4.8 `keep_arrival` is retired as a filter

`keep_arrival = !is.na(f_pass_arrived)` was classified as a **population** flag
on the argument that "a throw that arrived somewhere" is part of the question's
scope. §6 rejects that classification and the flag with it: the label is missing
on half of all incompletions, so it is neither a population definition nor
ignorable attrition.

The flag stays in `FLAG_LABELS` and `flag_marginals()` as a diagnostic (4,654
plays fail it), labeled `"diagnostic"` in `FLAG_GROUP`, and appears in no rule
— verified for `SCOPED_FLAGS`, `CONSERVATIVE_FLAGS`, and `QUESTION_RULE`.
Arrival is derived, not read.

### 4.9 Adopted: a targeted receiver is part of the population

**Decision.** The modeling population is thrown passes with a targeted
receiver, matching nflverse, which computes `cp` only when a receiver is named
(§8.4). Throwaways, spikes, intentional grounding, and passes with no
identifiable target are out of scope: the question is the completion
probability of a pass to a receiver, and these have none. Applied in `08`
(§0, §9.1).

On the 17,077 thrown passes in the analytic sample, BDB's targeted receiver
(`targetedReceiver.csv`, tracked) against nflverse's `receiver_player_name`:

| BDB target tracked | nflverse receiver named | n | complete |
|---|---|---|---|
| no (no target) | no | 407 | 0.0% |
| no (named, untracked) | yes | 25 | 84.0% |
| yes | no | 2 | 50.0% |
| yes | yes | **16,643** | 66.9% |

The two sources agree on 17,050 of 17,077 throws. Every throw with no target
recorded in BDB also has none in nflverse.

- **Population: nflverse receiver named.** Removes 409 throws (the 407 plus the
  2 discordant plays: a screen whose nflverse row lacks the receiver name, and a
  fumble-then-incompletion). The 407 are all incomplete or intercepted; this is
  why the exclusion is defended as a population definition rather than reported
  as attrition.
- **Quality: target tracked.** Removes 25 throws whose named target is not
  tracked, 84.0% complete — outcome-skewed in the opposite direction, small,
  and reported in the `08` funnel.
- **Result:** 16,643 throws, 66.9% complete, **every one carrying `cp`**. The
  model population and the benchmark's scoring population coincide, so the
  `has_cp` base-rate shift (§8.3) does not arise once this filter is applied.

**Implementation.** `QUESTION_RULE` in `R/sample_rules.R`, applied by `08`,
splits the base sample's `keep_target` into `keep_receiver_named` (population,
from nflverse `receiver_player_name`, now carried in `pbp.parquet`) and
`keep_target_tracked` (quality).

**Untargeted interceptions.** Four interceptions have no receiver in either
source. Reviewed on video: each is an unusual play for its own reason, and
all four are excluded by the targeted-receiver rule like any other untargeted
throw.

| Week | game_id / play_id | Game | Qtr | Clock | Down & dist | Note |
|---|---|---|---|---|---|---|
| 6 | 2018101405 / 1040 | ARI @ MIN | 2 | 14:25 | 3rd & 1 | short right, 7 air yards |
| 13 | 2018120206 / 2158 | BUF @ MIA | 2 | 0:05 | 1st & 10 | deep middle, end of half, QB hit |
| 14 | 2018121000 / 1786 | MIN @ SEA | 2 | 0:16 | 1st & 1 | −14 air yards, QB hit |
| 16 | 2018122300 / 1135 | NYG @ IND | 2 | 12:35 | 1st & 10 | deep right, end-zone interception |

**Spikes and scrambles are already out.** All 75 `qb_spike` plays fail
`keep_live_play` and `keep_any_throw`; all 7 `qb_scramble` plays fail
`keep_any_throw`. `08` keeps `keep_not_spike` and `keep_not_scramble` as
tripwires and asserts that they remove zero plays.

---

## 5. Coverage labels

**Eight labels collapse to a man/zone binary.** The eight-class cells have a
minimum of one play and cannot support an eight-class model.

**`Prevent Zone` maps to `NA`, not to zone.** A single garbage-time play. It
describes game *state*, not scheme, so it drops out of any coverage-conditional
sample rather than contaminating the zone class.

**The collapse lives in `classify_coverage()` in `R/coverage.R`, applied at the
sample layer.** `data/processed/coverages_week1.parquet` carries the original
eight-label `coverage` column verbatim, so a multi-class framing remains
available without a rebuild.

**Precedence is explicit:** `Man` is tested before `Zone`. No label in the 2018
week-1 vocabulary contains both.

**`02` asserts the vocabulary.** Any label that falls through the mapping other
than the one deliberate exclusion raises a build-time error.

**Descriptive only.** The observed completion-rate difference between man and
zone is confounded by down, distance, field position, and personnel. The
labeled week is 13 games (§3).

---

## 6. The arrival anchor

Reported in full in `analysis/02_arrival_anchor.qmd`. All counts below are
**week 1 only** ($n = 890$ plays with a tracked target, across 13 games) except
§6.1, which is full-season. The season-scale re-validation is §6.9.

Every coverage feature is anchored to two points: the ball at the throw, and the
ball at arrival. The throw is unambiguous. Arrival required three attempts.

### 6.1 The problem: `pass_arrived` missingness is selection on the response

On the 17,077 thrown passes in the analytic sample:

| `pass_result` | plays | missing `pass_arrived` | share |
|---|---|---|---|
| C | 11,148 | 92 | 0.8% |
| I | 5,531 | 2,797 | 50.6% |
| IN | 398 | 69 | 17.3% |

Completion rate of all thrown passes: $11{,}148 / 17{,}077 = 65.3\%$.
Completion rate requiring `pass_arrived`: $11{,}056 / 14{,}119 = 78.3\%$.

**A filter that looks like routine attrition would move the base rate of the
response variable by 13 percentage points, by deleting about half of all
incompletions.** Unlike §4.7 this cannot be handled by stating its direction in
Methods; it has to be avoided.

Missingness is flat across weeks (13.8%–19.7%), so it is a labeling convention
rather than a week-specific collection artifact.

`analytic_sample.parquet` still carries `t_arrive` and `t_flight`, derived from
`pass_arrived`. They are not to be modeled on.

### 6.2 Rejected: the `pass_outcome_*` family as a substitute anchor

Coverage is adequate — an outcome label (`caught`, `incomplete`,
`interception`, `touchdown`, earliest taken) exists on **99.7%** of plays.
Position is not. On plays carrying both labels, ball displacement between them:

| `pass_result` | p50 gap (frames) | p50 (yd) | p90 (yd) | p50 $\Delta x$ (yd) |
|---|---|---|---|---|
| C | 3 | 1.89 | 4.44 | +0.90 |
| I | 5 | 3.51 | 8.11 | +1.76 |
| IN | 5 | 2.30 | 5.95 | +1.06 |

The error is systematically downfield and its magnitude depends on the outcome.
The coverage features work at a scale of a couple of yards (separation, a
defender's reach), so a p90 error of 8 yd is
disqualifying. `pass_outcome_incomplete` fires when the ball hits the turf, well
past the receiver.

### 6.3 Rejected: first local minimum of ball-to-receiver distance

$f_{\text{arr}} = \min\{f : d_{f+1} > d_f\}$, on the reasoning that a local
minimum is the end of the flight by construction while a global minimum could
land after a bounce.

Three failure modes: **76 plays** returned flight times under $0.2$ s, because
one frame of jitter after release ends the search; the post-catch carry keeps
$d$ near zero for many frames so the first uptick is decided by noise
(disagreement with the global minimum on **318 of 564** completions); and on
badly thrown passes $d$ never rises, so the rule returned the window edge
(**41 of 295** incompletions). Completion p90 of $d_{\text{arr}}$ was $0.917$ yd
with a maximum of $28.4$ yd.

### 6.4 Rejected: closest approach within a tolerance $\epsilon$

$f_{\text{arr}} = \min\{f : d_f \le \min_g d_g + \epsilon\}$ with
$\epsilon = 0.25$ yd, presented as a tie-break across the near-zero plateau at
the coordinate rounding scale.

Face validity was good (completion p50 $d_{\text{arr}} = 0.300$ yd, max $1.13$
yd). Rejected on two counts:

1. **It failed its own sensitivity check.** Halving $\epsilon$ to $0.10$ changed
   the selected frame on **62%** of plays (agreement $0.382$, median shift 1
   frame in each direction). There is no plateau: $d$ shrinks gradually through
   the catch, so $\epsilon$ was *choosing how close counts as arrived* — a
   substantive modeling parameter presented as a numerical tolerance.
2. **The criterion is relative, so the standard varied by outcome.** With
   $\min d \approx 0$ on completions and $\approx 1$ yd on incompletions,
   $d \le \min d + \epsilon$ applied a different absolute threshold to each
   class.

### 6.5 Why: the carry phase

Ball per-frame displacement, indexed relative to the §6.4 anchor frame:

| frames from anchor | −8 | −5 | −3 | −2 | −1 | 0 | +1 |
|---|---|---|---|---|---|---|---|
| C | 2.13 | 2.05 | 1.77 | 1.23 | 0.70 | 0.62 | 0.50 |
| I | 2.05 | 2.10 | 2.08 | 2.01 | 1.88 | 1.83 | 1.21 |

Both classes fly at $\approx 2.1$ yd/frame ($\approx 21$ yd/s). Completions
decay to receiver speed by the anchor frame; incompletions hold flight speed
through it. The §6.4 anchor sits several frames *after* the ball stopped flying
on a completion, and those frames are the catch.

The distribution of ball `dis` over the search window is bimodal — carry and
dead ball below $\approx 1.0$, flight at $\approx 2.1$, valley floor around
$1.0$–$1.2$ yd/frame. The histogram belongs in the report as a figure.

### 6.6 Adopted: the last in-flight frame

$$f_{\text{arr}} = \max\{f \le f_{\min} : \texttt{dis}_f \ge \delta\},
\qquad f_{\min} = \arg\min_{f \in \mathcal{F}} d_f$$

over $\mathcal{F} = \{f : f_{\text{throw}} < f \le f_{\text{throw}} + 50\}$,
with $d_f$ the ball-to-targeted-receiver distance and
$\delta = \texttt{DIS\_FLIGHT} = \texttt{MAX\_DIS} = 1.3$ yd/frame.

**No term in the definition refers to the outcome.** One frame serves as both
the lane endpoint and the flight-time endpoint.

$\delta$ is defensible where $\epsilon$ was not because it separates two
physically distinct regimes rather than picking a point on a continuum.
`DIS_FLIGHT = MAX_DIS` **by argument**: `MAX_DIS` is the per-frame displacement
no player can exceed (§4.2), so a ball above it cannot be in anyone's hands. Set
as an alias in `R/constants.R`, so a revision of `MAX_SPEED` is a visible
decision about the arrival definition too.

Three components of the rule:

- **The $f \le f_{\min}$ bound** makes a post-bounce frame unreachable. Only 6
  plays of 890 show more than $1$ yd of rise between $f_{\text{arr}}$ and
  $f_{\min}$ (p99 rise $0.885$ yd), so the guard is belt-and-braces rather than
  load-bearing.
- **Runs of flight-speed frames separated by at most `ARRIVAL_GAP_TOL` frames
  are merged.** The two extremes are both wrong, and they disagree on **92 of
  890** plays (10.4%), median gap 2 frames, max 37. A tolerance of 0 lets one
  frame of jitter end the flight early; an unbounded tolerance lets a jittery
  frame during a catch-and-run be selected as the flight end. **Value set:
  `ARRIVAL_GAP_TOL = 2` frames**, from the sensitivity table in
  `analysis/02_arrival_anchor.qmd` §7.4, where $d_{\text{arr}}$ is stable across
  the grid and similar between classes.
- **The end of the first merged run, not its start.** The start is the release.

**Validation.**

- *Implied ball speed by 2-yd depth bin* — the decisive check, since a timing
  artifact would show up as outcome-dependent ball speed. Completions and
  incompletions agree within $\approx 1$ yd/s in all 11 bins, flat at
  $\approx 21$ yd/s across depth. Under §6.4 the same table split $12.0$ against
  $17.0$ yd/s at short depth, converging only past $26$ yd. Lane length matches
  across classes within each bin.
- *$\delta$ sensitivity* — frame agreement $0.869$ at $\delta = 1.0$ and $0.817$
  at $1.6$, median shift 0 in both directions, against $0.382$ for $\epsilon$.
- *Face validity* — median $d_{\min}$ on completions $0.121$ yd.
- *Class similarity* — median $d_{\text{arr}}$ of $0.696$ yd (C) and $1.16$ yd
  (I). A caught ball genuinely ends up closer to the receiver than a dropped
  one; similarity across classes, not proximity to zero, is the target.
- *Relationship to `pass_arrived`* — the label fires at a consistent
  ball-to-receiver distance across classes ($1.09$, $1.18$, $1.98$ yd). What
  differs by outcome is the remaining flight after that: median gap of $+3$
  frames on completions, $0$ on incompletions. Where the label fires first the
  gap closes monotonically (85% of completions, 94% of incompletions), so the
  label is **early** rather than marking a different event.

**Costs, stated for Methods.**

1. **Requires a tracked targeted receiver.** Consistent with the population
   definition in §4.9.
2. **The definition is the project's own construction**, not a dataset label.
   Validated against `pass_arrived` where that exists, and externally against
   nflverse `air_yards` (§6.8).
3. **Arrival timing is influenced by the outcome** to the extent that a caught
   ball's flight ends in the hands. The speed check bounds this at
   $\approx 1$ yd/s of implied speed.

**Diagnostics travel with the output and are not filtered on:** `d_arr`,
`d_min`, `f_min`, `frames_to_min`, `used_fallback`, `at_window_edge`.

`frames_to_min` is catch-plus-carry duration, not a gather time. Median 8
frames on completions, 0 on incompletions.

About 3% of plays never reach flight speed inside the window (`used_fallback`)
and fall back to closest approach: batted balls and soft flips with very short
lanes. Season-scale figures are in §6.9.

### 6.7 Two things `d_arr` must never be used for

**Not a model feature.** A ball ending up $0.12$ yd from the receiver *is* the
catch. `d_arr` or `d_min` in the feature set would drive log loss down while
saying nothing about coverage geometry.

**Not a filter.** A pass that never got near its target is a real play with real
coverage geometry, and almost by definition an incompletion. Excluding on
$d_{\text{arr}}$ would reintroduce the selection on outcome that §6.1 rejected.
Sensitivity to `used_fallback` and `at_window_edge` is checked at the model
stage instead.

### 6.8 Full-season checks

Run before any feature work, with the week-1 numbers above as the benchmark.
All five are reported in `analysis/04_arrival_season.qmd`; results in §6.9.

1. **Class similarity** of $d_{\text{arr}}$, all 17 weeks.
2. **Speed equalization** by 2-yd depth bin, all 17 weeks.
3. **Bounce check**, since a rarer artifact may only appear at 17× the sample.
4. **Three plays drawn around $f_{\text{arr}}$** — one completion, one
   incompletion, one interception — as static frame strips and as
   `render_play()` animations (GIFs in `figs/week06/`, not committed).
5. **External validation against `air_yards`.** Compare
   $x_{\text{arr}} - \texttt{los\_x}$ against nflverse `air_yards` (§8), an
   independently charted measurement of the same quantity. Also validates the
   sign convention and informs the beyond-the-LOS threshold (§7).

### 6.9 Season-scale results

`scripts/06_build_throw_frame.R` applies `detect_arrival()` to the 16,649 plays
in the analytic sample with a tracked target. **16,646 have an arrival.** The
other 3 have no frame after the throw on which both the ball and the target are
tracked: one play's tracking ends at the throw frame, and in two the targeted
receiver appears only on frames 1–2. (`target_tracked` records that the target
appears in the tracking data at all, not that they are tracked at the throw.)
553 plays (3.3%) use the closest-approach fallback; 57% of them arrive at or
behind the line of scrimmage. 7 arrive at the 5.0 s window cap.

**Week 1 reproduces the prototype:** 890 plays; median $d_{\text{arr}}$ 0.696
(C) and 1.16 (I); median $d_{\min}$ on completions 0.121; median
`frames_to_min` 8 (C).

| Check | Week 1 | All 17 weeks |
|---|---|---|
| Median $d_{\text{arr}}$, C / I / IN | 0.70 / 1.16 / 1.69 | 0.73 / 1.09 / 1.61 |
| Median $d_{\min}$, C | 0.12 | 0.12 |
| C − I implied speed, worst of 11 bins | ≈ 1 yd/s | 0.62 yd/s |
| Rise > 1 yd between $f_{\text{arr}}$ and $f_{\min}$ | 6 of 890 | 63 of 16,646 (0.38%); p99 0.60 yd |
| Frame agreement, $\delta$ = 1.0 / 1.6 | 0.869 / 0.817 | 0.858 / 0.783 |
| Frame agreement, gap tolerance 0 / 1 / 3 / 5 | — | 0.915 / 0.997 / 0.999 / 0.998 |

Flight time: p50 0.8 s, p99 3.0 s. The 551 flights under 0.4 s have median
depth −4.2 yd: shovels, screens, and batted balls at or behind the line.

**Implied ball speed is not flat across depth at season scale.** It rises from
about 18 yd/s on 8–10 yd lanes to about 22.5 yd/s beyond 18 yd, then levels
off. Completions and incompletions trace the same curve, so this is not an
outcome artifact. Short passes are thrown with more touch, and any fixed offset
in the `pass_forward` frame inflates flight time proportionally more on short
lanes; the data cannot separate the two. The week-1 description "flat at
≈ 21 yd/s" (§6.6) reflected the smaller sample.

**Visual check.** Three plays drawn four frames around arrival
(`figs/week06/arrival_frames.png`). The completion and incompletion show the
ball moving down the lane and sitting at the arrival point at $f_{\text{arr}}$.
The interception (Flacco scrambling to the right sideline and throwing deep;
intercepted 8.9 yd from the intended receiver) has the anchor on the last
flight frame before the defender's catch.

**External validation against `air_yards`** (16,641 throws with both):

| | Value |
|---|---|
| Correlation, $\text{depth}_{\text{arr}}$ vs `air_yards` | 0.965 |
| Median $\text{depth}_{\text{arr}} - $ `air_yards` | −0.68 yd (IQR −1.44 to 0.03) |
| Median difference, C / I / IN | −0.66 / −0.74 / −1.22 yd |
| Throws charted at exactly 0: median tracking depth | −0.70 yd; 77% at or behind the line |

The sign convention and line of scrimmage are right, and the offset does not
depend on the outcome. Tracking depth runs slightly short because the anchor is
the last in-flight frame, about one frame before the ball reaches the receiver,
while charting records the catch point; the shortfall grows on deep throws (mean
−2.1 yd at 20+ charted air yards), where the ball covers about 2 yd per frame.
Charted zero is a convention for throws at the line.

---

## 7. Open items

### Settled

**Research question.** Completion probability at the throw, predicted from
tracking-derived coverage geometry, on passes thrown beyond the line of
scrimmage to a tracked targeted receiver (§4.9). Separation is a feature of
that model rather than a separate question. Candidate geometry: receiver
separation and closing speed (stage 3); leverage, time-to-arrival, and the
passing window (stage 4).

Scoped out, with reasons: **coverage classification** (labels exist for week 1
only, §3, and there is recent published work), and **space-control / pitch-
control modeling** (time).

**Modeling strategy.** Binomial GAM via `mgcv` across four nested stages —
intercept only, play-by-play features, plus separation, plus full geometry —
with nflverse `cp` as an external benchmark rather than a fitted stage. The
headline is out-of-fold $\Delta$ log loss across stages, with game-clustered
intervals; calibration rather than AUC is the secondary diagnostic (reliability
overall and within separation and air-yards buckets). Leave-one-week-out
cross-validation. Details in §9.

### Closed

- The arrival anchor (§6) and `ARRIVAL_GAP_TOL = 2` (§6.6).
- The nflverse join: 19,238 of 19,239 plays, zero outcome disagreements (§8.2).
- nflverse `pass_attempt` includes sacks (§8.2).
- **`qb_hit` is a covariate, not a filter.** It does not distinguish "hit
  during the throw" from "hit after", so excluding it would remove real passes
  and may itself select on outcome. Present on 2,761 plays on the spine (14.4%).
  It enters stage 2 as a depth-varying effect (§9.3).
- **Targeted receiver as population** (§4.9). This also closes two earlier
  checks: throwaways and spikes carry no BDB target (all 407 untargeted throws
  in the analytic sample; all 75 spikes), so no separate pbp-derived throwaway
  flag is needed.
- **Spikes and scrambles** are already out of the base sample (§4.9).
- **Four untargeted interceptions** reviewed on video and excluded with the
  other untargeted throws (§4.9).
- **Passing window: time-based, with no fixed-width corridor.** A fixed width
  (the earlier "2 yd or 3 yd" item) is a crude stand-in for whether a defender
  can get into the ball's path, which depends on the defender's distance and
  velocity and on the ball's flight time, and it would add a free parameter. The
  passing window is built on the time-to-arrival machinery (`time_to_point()`)
  and covers **defenders other than the nearest defender to the targeted
  receiver**, who is measured by separation in stage 3.
  - **Nearest defender** is determined at the throw frame, as separation is.
  - **Each defender is timed to their best intercept point along the lane.**
    At lane fraction $u \in [0, 1]$ (release to arrival) the ball arrives at
    about $uT$, with $T$ the flight time (reasonable given the near-constant
    implied speed in §6.9), and defender $j$ needs $\tau_j(u)$ from
    `time_to_point()`. The defender's margin is
    $m_j = \max_u \, [\, uT - \tau_j(u) \,]$, in seconds; positive means
    the defender can get into the ball's path before it passes. Timing only to
    the arrival point would mostly measure help coverage at the catch.
  - **Model feature: the largest margin** across those defenders — how well
    placed the best help defender is. One continuous value with no threshold,
    entered as a smooth. The count of defenders with a positive margin is
    reported descriptively only: as a feature it would reintroduce a hard
    cutoff (at 0 s) and is mostly 0 or 1. Plays with no other tracked defender,
    and ties for the nearest defender at the throw frame, are handled
    explicitly in `07`.
  - No ball height: a defender who can reach the middle of a high deep throw
    counts as in the window although the ball passes over. Stated, not patched.
- **Beyond-the-LOS threshold: $\text{depth}_{\text{arr}} > 0$**, the ball
  arrives beyond the line of scrimmage (§6.9). A population filter, applied in
  `08`. On the 16,641 throws with both measures:

  | Rule | Kept | Kept, charted ≤ 0 | Dropped, charted > 0 | Complete, kept / dropped |
  |---|---|---|---|---|
  | $\text{depth}_{\text{arr}} > 0$ | 13,147 (79.0%) | 330 | 453 | 63.8% / 78.4% |
  | $\text{depth}_{\text{arr}} > 0.5$ | 12,796 (76.9%) | 230 | 704 | 63.4% / 78.4% |
  | $\text{depth}_{\text{arr}} > 1$ | 12,376 (74.4%) | 170 | 1,064 | 62.7% / 78.8% |
  | `air_yards` > 0 (charted) | 13,270 (79.7%) | — | — | 63.3% / 81.0% |

  Zero follows from the definition rather than a fit; it keeps within 123 throws
  of the charted rule and disagrees with it on 4.7% of throws. Raising the
  threshold mostly drops throws charted beyond the line. The excluded throws are
  mostly screens and other easy completions, so the filter is a population
  definition, reported with its composition. Consequence for stage 2: once
  $\text{depth}_{\text{arr}}$ replaces `air_yards`, `air_yards_zero` (a
  charting artifact) leaves the spec.
- **`keep_arrival`** appears in no rule (§4.8).
- **Resampling unit for $\Delta$ log loss intervals: game** (§9.5).
- **Calibration method** (§9.6) and **`cp` benchmark method** (§9.7): fixed
  external predictions, no recalibration.
- **Depth control: $\text{depth}_{\text{arr}}$ replaces charted `air_yards`
  in stage 2**, and the `air_yards == 0` indicator is dropped (§9.3).
- **Stage 2 depth interaction: QB hit × depth** (§9.3). Decided before any
  stage 3 result exists. Stage 3–4 results are still reported by depth.
- **Leverage enters as a direction** (`lev_angle`, cyclic smooth), since its
  magnitude is `sep_throw` (§9.9).
- **Stage 4 deep-throw calibration** (slope 0.86 [0.73, 0.996] on 20+ yd) is
  reported, not corrected: it is the last stage (§9.9).
- **Robustness checks** (§9.11): charted `air_yards`, p90 motion constants,
  and excluding arrival fallbacks, kinematic defects, QB-hit plays, and
  `at_window_edge` plays. None moves the stage comparisons materially.
- **Stage 3 depth interaction: separation × depth**, `ti(sep_throw, depth_arr)`
  (§9.8). Without it stage 3 was too extreme on deep throws (calibration slope
  0.73 [0.59, 0.86] on 20+ yd), the same pattern as QB hit before its
  interaction. Chosen over waiting for stage 4's time-based features, so that
  stage 3 is calibrated as a baseline for stage 4.

### Open

- **Penalty-nullified plays.** All 633 are currently excluded by `keep_los`
  (§4.7), not by decision. Retaining them, or running the `keep_official_play`
  sensitivity, first requires recovering `los_x` for them, e.g. from the ball
  position at the snap.
- **Man/zone** — whether the binary earns a place in the model, given §5 and
  the 13-game denominator.
- **QB kinematic state** — listed among the geometry features in earlier
  framing but not assigned to stage 3 or 4.

### Play types measurable but not yet filtered

`SAMPLE_RULE` is question-agnostic by design. Status of play types that may be
inappropriate for this question:

| Play type | Status |
|---|---|
| QB spikes | Already out of the base sample (§4.9) |
| Throwaways, intentional grounding, untargeted passes | Out via the targeted-receiver population (§4.9) |
| Penalty-nullified plays | Already out via `keep_los` (§4.7); open above |
| Screens and other passes behind the LOS | Beyond-the-LOS filter, $\text{depth}_{\text{arr}} > 0$ (applied in `08`) |
| Batted or tipped passes at the line | Not yet flagged |
| Hail Marys | Not yet flagged |
| Goal-line plays with extra linemen | Not yet flagged |
| Two-point conversions | Not yet checked |

### Feature state

The full pipeline, scripts 01–08, is built. `model_frame.parquet` (13,125
throws) is the scoring population for stages 1–4 and the `cp` benchmark (§9).
Robustness checks are done (§9.11). Remaining work is the report.

### Deferred to future work

- Assigned-defender separation (needs coverage classification)
- Passes behind the LOS — screens have different separation dynamics
- An at-arrival model as $\hat p_{\text{arrival}} - \hat p_{\text{throw}}$, a
  defender "closing space" credit
- Position-specific motion parameters
- Ordinal C/I/IN response

---

## 8. The nflverse play-by-play join

`scripts/05_join_pbp.R`, with the bridge in `R/pbp.R`. Outputs
`data/processed/pbp.parquet` (one row per play, on the plays keys) and
`pbp_outcome_agreement.parquet` (the join check, persisted).

**Why the join exists.** Four things the Kaggle download does not have: `cp`
(the external benchmark), `air_yards` (BDB's `plays.csv` carries no throw depth),
the pressure and spike flags, and game-state context. Everything else the
play-by-play model stage needs was already in `plays.parquet`.

**Counts in this section are on the full 19,239-play spine** unless stated.

### 8.1 Provenance and keys

**Pull.** `nflreadr` 1.5.1, nflverse data release 2025-04-30, 47,109 rows ×
372 columns, mirrored verbatim to `data/interim/pbp_2018.parquet` with a
provenance sidecar (`pbp_2018_meta.parquet`). nflverse revises its data between
releases, so results produced in October have to reproduce in December.
`nflverse_timestamp` is an attribute on the returned object and does not survive
a Parquet round trip, so the sidecar is written at download time. A mirror
without its sidecar triggers a re-pull.

**Keys.** `gameId` → `old_game_id` (character, cast to `int32`), `playId` →
`play_id` (double, cast to `int32`). `standardize_pbp_keys()` errors on an
unparseable or duplicated key. nflverse's own `game_id` (the `2018_01_ATL_PHI`
schedule key) is dropped rather than carried alongside.

**Game sets, compared in both directions.** 0 BDB games absent from nflverse —
asserted. 14 nflverse games absent from BDB: 11 postseason plus the 3 week-1
games BDB omits (§3).

### 8.2 The join is verified on identity, not coverage

A high proportion of keys finding a partner is consistent with having matched
real keys to the *wrong* plays, which would put one play's air yards beside
another play's coverage geometry and still produce plausible log loss. So the
join is verified using two facts both sources record independently.

| Check | Result |
|---|---|
| Key match rate | 19,238 / 19,239 (99.9948%). The single unmatched play is a Q4 completion. |
| Outcome cross-tab | **0 disagreements** across 18,605 checkable plays carrying a real nflverse pass outcome |
| Week redundancy (`week` vs `week_pbp`) | 0 mismatches — asserted |
| Description token similarity | p10 $0.81$, p50 $0.86$, 90.9% above $0.8$ |

**`pass_attempt` is 1 on sacks**, so no sack falls through to the
no-pass-recorded class.

**Exact description agreement is near zero by construction.** nflverse prefixes
every player with a jersey number (`9-M.Stafford` against `M.Stafford`) and uses
different team abbreviations from BDB's description strings (`LV`/`OAK`,
`ARI`/`ARZ`, `CLE`/`CLV`, `HOU`/`HST`). A 40-character prefix comparison agreed
on 5 of 19,238 plays and was replaced by Jaccard overlap on whitespace tokens,
which is invariant to insertions, deletions, and reordering.

**Three kinds of non-agreement are separated in `outcome_agreement()`**: a
checkable play whose real pass outcome disagrees (indicts the join); a play with
no pbp row; and a matched play where nflverse logged no pass (§8.3).

### 8.3 The penalty-nullified block is selected on outcome

**633 plays** carry `play_type == "no_play"`. Every one carries BDB penalty
codes; **237 are defensive pass interference**. Of these, 627 are a genuine
disagreement between the two feeds about whether a pass occurred; the remaining
6 are 4 scrambles (where "no pass recorded" is the correct answer) and 2 plays
with no BDB `pass_result`.

| | n | Complete | Incomplete | Intercepted |
|---|---|---|---|---|
| Not nullified | 17,345 | 65.0% | 32.7% | 2.3% |
| Nullified | 579 | **17.8%** | **79.8%** | 2.4% |

Defensive PI nullifies incompletions, which is the mechanism.

**These are the missing-LOS plays (§4.7).** All 633 lack BDB's play-level
metadata and fail `keep_los`, so **none is in `analytic_sample.parquet`**. They
also lack `air_yards`, and **`cp` is `NA` on all 633**.

**Decision, revised.** The earlier provisional decision was to retain nullified
plays in the tracking-stage sample, on the argument that BDB's `pass_result`
records what physically happened to the football and the coverage geometry is
real. That decision was never in effect: `keep_los` removes them first. They
are currently out, the exclusion is outcome-skewed and stated in Methods, and
retaining them is an open item that requires recovering their line of
scrimmage (§7).

**Benchmark base rate.** Thrown passes (BDB C, I, IN) on the spine complete at
**63.4%**; on the `has_cp` subset, **66.9%**. Two blocks drive the gap: the
nullified plays and the untargeted throws (§8.4), both overwhelmingly
incomplete. On the analytic sample's throws the figures are 65.3% and 66.9%.
Under the §4.9 population every play carries `cp`, so the gap disappears.

**A constraint on the money table.** $\Delta$ log loss across model stages is
only comparable when every stage is scored on the same rows.

### 8.4 Availability

| Column | Present | Share of spine |
|---|---|---|
| `pbp_matched` | 19,238 | 99.99% |
| `cp` | 16,853 | 87.6% |
| `air_yards` | 17,343 | 90.1% |

**`cp` is present exactly when `air_yards` is present and nflverse names a
receiver.** Among the 17,343 plays with `air_yards`, all 16,853 with a named
receiver carry `cp` and none of the 490 without one does. Those 490 are 75 QB
spikes, 411 incompletions, and 4 interceptions — **zero completions**:
throwaways, intentional grounding, and passes with no identifiable target. 406
of them are in the analytic sample; the targeted-receiver population (§4.9)
removes them. The remaining plays without `cp` are the 633 nullified plays and
1,263 other plays without `air_yards`, one of them unmatched.

`air_yards` on the spine: 2,529 negative, 1,093 exactly zero, 20.9% at or below
zero — the provisional cost of the beyond-the-LOS filter (§7).

Flags: `qb_hit` 2,761 (14.4%), `qb_spike` 75, `qb_scramble` 7,
`play_type == "no_play"` 633.

`has_cp` and `has_air_yards` travel with the data rather than being filtered
on. `pbp_matched` is set on the pbp table *before* the join, because `cp` and
`air_yards` are legitimately missing on matched rows.

### 8.5 Leakage discipline

**Excluded as leaks**, asserted by `assert_no_leak_cols()` against both exact
names and regex families: `cpoe` — which is
$100 \times (\texttt{complete\_pass} - \texttt{cp})$ and therefore contains the
response exactly — every EPA and WPA derivative, `yards_gained`,
`yards_after_catch`, and BDB's own `epa`, `play_result`, and
`offense_play_result`.

A leak of this kind is invisible in a log-loss table: the model simply looks
excellent. Hence a named constant with a build-time assertion.

Pre-play quantities are deliberately **not** excluded: `ep`, `wp`, `vegas_wp`,
`spread_line`, `total_line` are legitimate context features.

**`pbp.parquet` deliberately retains the outcome columns** (`complete_pass`,
`interception`, `sack`, `pass_attempt`, `play_type`) so §8.2 can be re-run from
the persisted artifact. `assert_no_leak_cols()` exempts them by default;
**`08_build_model_frame.R` must call it with `allow = character(0)`** so they
are rejected in the model frame.

### 8.6 Not modeled

- **`pass_length`** (the short/deep factor). Charted independently of BDB,
  disagrees with it on at least one observed play, and is `air_yards` binned at
  15 yards.
- **`qb_spike`, `qb_scramble`** — not features; those plays are already outside
  the population (§4.9).
- **`cp` caveats, for Methods.** nflfastR's completion probability model was
  trained on seasons including 2018, so its predictions here are partly
  in-sample. It also depends on human-charted air yards unavailable to a
  tracking-only model. It remains the field-standard reference, and the claim it
  supports is "tracking geometry adds information beyond play-by-play," not
  "we beat `cp`."

---

## 9. Models and evaluation

Implemented in `R/evaluate.R`, reported in `analysis/03_model_baseline.qmd`.
The model frame is built by `scripts/08_build_model_frame.R` and the models are
fit by `scripts/09_fit_models.R`. Numbers are on
that final population unless marked otherwise; results on earlier populations
are summarized in §9.10.

### 9.1 Response and scoring population

`complete = 1` for C; I and IN are 0, which matches nflverse `cp` and makes the
benchmark comparable.

`08` joins `analytic_sample.parquet`, `number_of_pass_rushers` from
`plays.parquet`, `pbp.parquet`, `arrival.parquet`, and `features.parquet`, and
applies `QUESTION_RULE` (`model_funnel.parquet`):

| Step | Dropped | Remaining | Complete (kept) | Complete (dropped) |
|---|---|---|---|---|
| analytic sample | — | 17,081 | 65.3% | — |
| thrown pass, C / I / IN (population) | 4 | 17,077 | 65.3% | 0.0% |
| nflverse receiver named (population, §4.9) | 409 | 16,668 | 66.9% | 0.2% |
| not a spike; not a scramble (tripwires) | 0 | 16,668 | 66.9% | — |
| targeted receiver tracked (quality) | 25 | 16,643 | 66.9% | 84.0% |
| arrival measured (quality, §6.9) | 3 | 16,640 | 66.9% | 0.0% |
| ball arrives beyond the line, $\text{depth}_{\text{arr}} > 0$ (population, §7) | 3,493 | 13,147 | 63.8% | 78.4% |
| every model input defined (quality) | 22 | **13,125** | 63.8% | 72.7% |

The 22 complete-case drops (16 completions, 6 incompletions; 0.2% of throws)
lack a stage 3 or 4 input: a player's direction is missing at the throw, which
leaves `closing_throw`, `tta_nearest`, or `window_margin` undefined, or the ball
did not move between the throw and arrival frames, which leaves `lev_angle`
undefined. The requirement is the union across all specs, so they leave every
stage. Scoring population: **13,125 throws, base rate 0.6377**, every one
carrying `cp`.

**Assert, don't filter.** `assert_complete()` fails on any NA in any spec
variable rather than dropping rows, and every fit uses `na.action = na.fail`:
`glm()` and `gam()` would otherwise drop rows per stage and score stages on
different populations.

### 9.2 Derived predictors

- **Rare factor levels** (fewer than 100 plays) are lumped into `"other"` so no
  level is absent from a training fold. Affects nothing in the current spec;
  written when `offense_formation` was in the model (WILDCAT: 31 plays, 17 in
  week 14). `NA` stays `NA`.
- **`number_of_pass_rushers` clamped to [2, 7].** On the 17,077 throws before
  the population filters this moved 117 plays (values 0: 16, 1: 72, 8: 28,
  9: 1). Zero rushers on a pass play is a charting artifact, and sparse tails
  would be extrapolated in the folds that hold them out.
- **`dist_to_sticks = depth_arr - yards_to_go`** replaces `yards_to_go`.
  Additive smooths in depth and `yards_to_go` cannot represent whether the
  throw reaches the line to gain; all three together are linearly dependent.
- **`home`**: offense is the home team.

### 9.3 Stage specifications

Stage 1: intercept-only `glm()`.

Stage 2 (`mgcv::gam()`, REML):
`s(depth_arr) + s(dist_to_sticks) + s(los_x) + s(number_of_pass_rushers, k = 5)
+ s(depth_arr, by = qb_hit) + down + pass_location + shotgun + home`.

Stage 3: stage 2 + `s(sep_throw) + s(closing_throw) + ti(sep_throw, depth_arr)`
(§9.8).

Stage 4: stage 3 + `s(lev_angle, bs = "cc", k = 8) + s(tta_nearest) +
s(window_margin)`, with the cyclic smooth's knots at $\pm\pi$ (§9.9).

`R/evaluate.R` asserts that each stage contains every term of the one before.

**The nesting is the argument.** Stage 2 already knows the situation and the
throw's depth, so later stages must earn their improvement on coverage
information alone. Every term removed from stage 2 makes the headline delta
larger and less defensible, so **baseline terms are cut by argument, never by
in-sample $p$-value.**

**Depth is the tracking-derived $\text{depth}_{\text{arr}}$** (§6.9), which
replaced charted `air_yards` once `06` existed. The `air_yards == 0` indicator
went with it: it captured the charting convention of recording throws at the
line as exactly zero, and the tracking depth is continuous. A refit with
charted `air_yards` is a robustness check (§9.11).

Stage 2 follows `cp`'s feature set where BDB supports it. Departures:

- **Three pass locations**, not middle/not-middle. Against left, middle is
  $+0.257$ (SE 0.050) and right $-0.060$ (SE 0.045, $p = 0.18$). Middle differs
  from both sides; left and right differed by about 3.6 SE on the population
  before any filter and are not distinguishable on this one. The three-level
  coding is kept rather than revised on a $p$-value.
- **`number_of_pass_rushers` added** ($\chi^2 = 16.8$, edf 1.01): a defensive
  control, so stage 3–4 features cannot be said to recapture rushers versus
  droppers.
- **The QB-hit effect varies with depth** (below).
- `roof` and era omitted: era is meaningless in one season, and `roof` is not
  in `PBP_COLS`.

Tested and dropped during specification, on the population before any filter:

- **`offense_formation`**: describes scheme rather than difficulty, and is
  aliased with `shotgun` (an empty-backfield snap is essentially always from
  shotgun), inflating standard errors from about 0.04 to about 0.35.
- **`defenders_in_the_box`** and **`score_differential`**: edf about 1.00 and
  $p > 0.05$, and droppable by argument — the box count is vendor-charted with
  implausible tail values, and the blowout mechanism behind score differential
  is absent from the data.

**Retained despite being weak:** `s(dist_to_sticks)`, edf 1.77, $p = 0.39$. It
is the model's only `yards_to_go` information.

**Adopted: QB hit × depth**, as `s(depth, by = qb_hit)` in place of a single
`qb_hit` coefficient. A smooth with a numeric `by` is not centered, so it carries
the level of the hit effect and there is no separate `qb_hit` term. Diagnosed
on the targeted-receiver population with charted air yards, before the
beyond-the-line filter: out-of-fold term contributions refit within each
air-yards bucket showed `qb_hit` departing from its full-sample strength,
monotonically in depth.

| Air yards | Plays with a hit | Observed hit effect (logit) | Model's hit effect (logit) |
|---|---|---|---|
| ≤ 0 | 219 (6.5%) | −1.57 | −0.87 |
| 1–9 | 548 (7.1%) | −0.94 | −0.81 |
| 10–19 | 407 (11.3%) | −0.49 | −0.82 |
| 20+ | 251 (12.6%) | −0.32 | −0.78 |

On deep throws the constant effect underpredicted hit plays (29.9% observed,
22.6% predicted) and overpredicted the rest (36.9%, 39.0%). The argument is
about the measurement, not a $p$-value: `qb_hit` records a hit on the play, not
its timing, and on deep throws the hit more often comes after the release.
`s(air_yards)` and pass location held their strength on deep throws in the same
diagnosis. When adopted, out-of-fold log loss improved by 0.0012 nats [0.0003,
0.0021] and the deep-bucket slope moved from 0.62 to 0.76. The change was made
after seeing stage 2's out-of-fold results but before any stage 3 or 4 result
existed. On the final population the fitted hit effect is −1.05 at 2 yd, −0.65
at 10, −0.39 at 20, and −0.16 at 30.

Other stage 2 effects on the final population: `shotgun` $-0.278$ (SE 0.054) —
conditional on depth, shotgun passes complete less often; third down $-0.17$
(SE 0.053). `s(depth_arr)` edf 3.54; the hit-by-depth smooth edf 3.33.
Deviance explained **8.74%** in-sample.

### 9.4 Resampling and fitting

- **Leave-one-week-out**, 17 folds. Plays within a game share a quarterback, a
  defense, and conditions; a random split lets the model see a test play's own
  game and returns an optimistic estimate with no signature (Roberts et al.,
  2017).
- **Pooled out-of-fold predictions**, not averaged per-fold metrics: with
  unequal folds the two differ, and only pooled predictions can be subset
  without refitting.
- **REML** smoothness selection rather than mgcv's GCV default.
- Predictions on the response scale, asserted complete and strictly inside
  (0, 1).
- **Fit once, by a script.** `09_fit_models.R` writes the pooled out-of-fold
  predictions (`data/processed/oof_preds.parquet`, one row per play and stage:
  4 × 13,125 = 52,500 rows), a manifest (`oof_specs.parquet`: each spec as
  text, a hash of the model inputs, R and mgcv versions), and the fits on all
  rows (`models/full_fits.rds`, 7.8 MB). Every metric in §9.5–9.11 is a
  function of the outcome, the out-of-fold predictions, and model-frame
  columns, so the 68 fold fits are not kept. The notebooks read through
  `read_oof_preds()` and `read_full_fits()`, which stop if any spec's
  engine, formula, or knots differs from the manifest, a stage was added or
  removed, or the hash of the model-frame columns the specs use has changed;
  a change to any other column does not trigger a refit. `cp` is appended
  from the model frame on read rather than stored twice. 09 reproduces the
  notebook's out-of-fold log losses exactly (0.6548, 0.5994, 0.5550, 0.5431)
  and takes about 3 minutes.
- **Rejected:** Quarto `freeze`/`cache` (freeze is skipped when one file is
  rendered, and neither tracks `R/` or `data/`), keeping the fold fits (no
  metric needs them), and a wide table (the scoring functions take one row
  per play and model, and a new stage would change the schema).

### 9.5 Scoring

**Log loss**, in nats, computed by hand (`pointwise_log_loss()`), with no
clipping: a prediction of exactly 0 or 1 is an error, not a large penalty.
yardstick is not used because it clips by default and treats the first factor
level ("0") as the event.

Reference point: a constant prediction at $\bar y$ scores $H(\bar y)$. Stage 1
out of fold cannot score below it, because each held-out week is predicted by
the other weeks' rate, which lies on the far side of $\bar y$ from that week's
own rate. Both checks are asserted in the notebook.

| | Out-of-fold log loss |
|---|---|
| $H(\bar y)$, $\bar y = 0.6377$ | 0.6547 |
| Stage 1 | 0.6548 |
| Stage 2 | 0.5994 |
| nflverse `cp` | 0.5900 |
| Stage 3 | 0.5550 |
| **Stage 4** | **0.5431** |

**Paired $\Delta$ log loss** (`paired_delta()`): the mean of per-play
differences, with a cluster bootstrap percentile interval (10,000 draws) that
holds the out-of-fold predictions fixed.

**Resampling unit: game** (253 clusters). Week (17 clusters) matches the folds
but is too few for a percentile bootstrap, and is reported as a sensitivity
check.

| Stage 2 − stage 1 | $\Delta$ | 95% interval | SE (bootstrap) | SE (analytic) | SE (iid) | Design effect |
|---|---|---|---|---|---|---|
| game | −0.0554 | [−0.0614, −0.0496] | 0.00301 | 0.00300 | 0.00285 | 1.10 |
| week | −0.0554 | [−0.0612, −0.0496] | 0.00296 | 0.00308 | 0.00285 | 1.16 |

Clustering matters little for this comparison: game-level factors affect both
stages' losses alike and largely cancel in the paired difference. Game
clustering is kept because coverage-feature gains may concentrate by game.

Rejected: unpaired comparison of two intervals (ignores the shared play-level
difficulty); a play-level bootstrap (ignores within-game dependence); refitting
inside the bootstrap (about 340,000 fits).

### 9.6 Calibration

**Measures** (Van Calster et al., 2019): calibration-in-the-large
$\text{CITL} = \bar y - \bar{\hat p}$; the calibration intercept $a$ in
$\operatorname{logit} P(y = 1) = a + \operatorname{logit}\hat p$; and the
calibration slope $b$ in
$\operatorname{logit} P(y = 1) = a' + b\operatorname{logit}\hat p$ (1 when
calibrated, below 1 when predictions are too extreme). Intervals are
game-cluster bootstrap percentiles (2,000 draws overall, 1,000 per subgroup)
with predictions held fixed. ECE is not reported because it depends on the
binning.

**Display:** a smoothed calibration curve (binomial GAM of the outcome on
$\operatorname{logit}\hat p$, pointwise 95% band) with 20 equal-count bins.
Figures: `figs/week06/calibration.png`, `calibration_by_depth.png`.

**Subgroups:** depth buckets on $\text{depth}_{\text{arr}}$ with edges fixed in
advance — 0–10, 10–20, 20+ yd (`depth_bucket()`). Separation buckets are a
possible addition.

| | CITL | Slope |
|---|---|---|
| Stage 2 | 0.000 [−0.009, 0.009] | 0.987 [0.933, 1.045] |
| `cp` | 0.012 [0.003, 0.020] | 1.061 [1.008, 1.116] |
| Stage 3 | 0.000 [−0.009, 0.009] | 0.987 [0.940, 1.033] |
| Stage 4 | 0.000 [−0.008, 0.009] | 0.988 [0.945, 1.033] |

| Depth (n) | Stage 2 slope | Stage 3 slope | Stage 4 slope | `cp` slope |
|---|---|---|---|---|
| 0–10 (7,953) | 0.94 [0.83, 1.05] | 0.98 [0.91, 1.05] | 1.00 [0.94, 1.07] | 1.07 [0.96, 1.18] |
| 10–20 (3,495) | 1.16 [1.007, 1.34] | 1.02 [0.92, 1.12] | 0.99 [0.90, 1.08] | 1.19 [1.05, 1.33] |
| 20+ (1,677) | 0.84 [0.54, 1.18] | 0.90 [0.74, 1.07] | 0.86 [0.73, 0.996] | 1.46 [1.14, 1.80] |

Stage 2's CITL contains zero in every bucket; `cp` underpredicts on short
throws (0.014 [0.004, 0.023]). Stage 2 is slightly too timid at intermediate
depth. **`cp` is slightly miscalibrated beyond the line of scrimmage**:
it underpredicts and is too timid, most of all on deep throws. It was fit to all
passes, including the screens removed here, so some miscalibration on a
subpopulation is expected. Stage 3 is calibrated overall and within sampling
error of 1 in every depth bucket, once separation interacts with depth (§9.8).
Stage 4 is calibrated overall but slightly too spread out on deep throws (§9.9).

### 9.7 The `cp` benchmark

`cp` is scored as a fixed external set of predictions on the same 13,125 rows;
it is not refit or recalibrated.

| Comparison (game clusters) | $\Delta$ | 95% interval |
|---|---|---|
| Stage 2 − `cp` | +0.0093 | [+0.0071, +0.0115] |
| `cp` − stage 1 | −0.0647 | [−0.0707, −0.0591] |
| Stage 3 − `cp` | −0.0350 | [−0.0405, −0.0295] |
| Stage 4 − `cp` | **−0.0470** | [−0.0530, −0.0409] |

`cp` beats stage 2 by 0.0093 nats, so stage 2 captures 86% of `cp`'s
improvement over the base rate. `cp` leads despite its miscalibration, so the
gap is in discrimination. Plausible sources, not separable here: `cp`'s model
class represents interactions, it is trained on far more plays, and 2018 is
partly in its training data. Stages 3 and 4 overtake it (§9.8, §9.9).

### 9.8 Stage 3: separation at the throw

**Features** (`scripts/07_build_features.R`, `features.parquet`), at the throw
frame. With $\mathbf{x}_r$ the targeted receiver and $D$ the tracked defenders,
the nearest defender is
$j^* = \arg\min_{j \in D} \lVert \mathbf{x}_j - \mathbf{x}_r \rVert$ and

$$
\texttt{sep\_throw} = \lVert \mathbf{x}_{j^*} - \mathbf{x}_r \rVert, \qquad
\texttt{closing\_throw} =
\frac{(\mathbf{v}_{j^*} - \mathbf{v}_r) \cdot (\mathbf{x}_{j^*} - \mathbf{x}_r)}{\texttt{sep\_throw}}
$$

with velocities from speed and direction; closing speed is negative when the
defender is gaining.

- **At the throw**, because the question is the completion probability at
  release; separation at arrival is partly the catch.
- **Nearest defender**, not assigned: assignment needs coverage labels (§3).
- **Analytic closing speed**, defined at a single frame, rather than
  differenced positions.
- **Smooths** in both. Ties for the nearest defender go to the lower `nfl_id`;
  there are none. Missing `dir` propagates to NA rather than being imputed
  (5 plays of 16,646; 2 in the population).
- **Separation × depth**, `ti(sep_throw, depth_arr)`, alongside the main
  effects. On a deep throw the ball is in the air long enough for separation at
  the release to change before it arrives, so separation should matter less.
  Without the interaction, stage 3 applied separation's full-sample effect to
  deep throws and was too extreme there: calibration slope 0.73 [0.59, 0.86] on
  20+ yd. With it, the slope is 0.90 [0.73, 1.07], deep-throw log loss improves
  from 0.6271 to 0.6216, and overall log loss by 0.0009 nats [−0.0000, 0.0019].
  Chosen over waiting for stage 4, so that stage 3 is a calibrated baseline for
  stage 4. As with QB hit × depth, the change was made after seeing stage 3's
  out-of-fold results but before any stage 4 result exists.

Completion by separation at the throw: 29.9% at 0–1 yd, 47.9% at 1–2, 62.7% at
2–3, 72.9% at 3–5, 80.4% at 5–8, 84.4% beyond 8 yd.

**Results** (13,125 throws, out of fold):

| | $\Delta$ | 95% interval |
|---|---|---|
| Stage 3 − stage 2 (game) | **−0.0444** | [−0.0495, −0.0392] |
| Stage 3 − stage 2 (week) | −0.0444 | [−0.0478, −0.0404] |
| Stage 3 − `cp` (game) | −0.0350 | [−0.0405, −0.0295] |

Separation adds 0.0444 nats, about 80% of stage 2's whole gain over the base
rate (0.0554), and moves the model from 0.0093 nats behind `cp` to 0.0350 ahead.
In-sample deviance explained rises from 8.74% to 15.75%; `s(sep_throw)` edf
7.55, `s(closing_throw)` edf 6.40, `ti(sep_throw, depth_arr)` edf 2.92.
Stage 3 is calibrated overall and in every depth bucket (§9.6), so the
improvement is not overfit.

**By depth** (game clusters):

| Depth (n) | Stage 2 log loss | Stage 3 − stage 2 | Share of stage 2 loss |
|---|---|---|---|
| 0–10 (7,953) | 0.5615 | −0.0477 [−0.0547, −0.0406] | 8.5% |
| 10–20 (3,495) | 0.6623 | −0.0454 [−0.0557, −0.0350] | 6.9% |
| 20+ (1,677) | 0.6481 | −0.0264 [−0.0375, −0.0151] | 4.1% |

Separation still helps least on deep throws, where separation at the release
says least about separation at the catch. That is what stage 4's time-based
features are designed to address.

### 9.9 Stage 4: coverage geometry at the throw

**Features** (`scripts/07_build_features.R`), at the throw frame, on the lane
from the ball at the throw $\mathbf{x}_0$ to the arrival point $\mathbf{x}_1$,
with unit direction $\mathbf{u}$ and flight time $T$.

- **Leverage as a direction.** For the nearest defender $j^*$, with
  $\boldsymbol\delta = \mathbf{x}_{j^*} - \mathbf{x}_r$:
  $\ell_\parallel = \boldsymbol\delta \cdot \mathbf{u}$ and $\ell_\perp$ the
  signed offset across the lane, re-signed so positive is toward the middle of
  the field (`to_inside_outside()`). Because
  $\ell_\parallel^2 + \ell_\perp^2 = \text{sep}^2$ and stage 3 already has
  $\text{sep}$, the three cannot enter together; leverage enters as
  $\texttt{lev\_angle} = \operatorname{atan2}(\ell_\perp, \ell_\parallel)$ —
  0 over the top, $\pm\pi$ underneath, $+\pi/2$ inside, $-\pi/2$ outside — as a
  cyclic smooth on $[-\pi, \pi]$ ($k = 8$). Undefined on 11 plays where the ball
  did not move between the throw and arrival frames (3 beyond the line; all
  closest-approach fallbacks).
- **Time to arrival** of the nearest defender:
  $\texttt{tta\_nearest} = T - \tau_{j^*}(\mathbf{x}_1)$, with $\tau$ from
  `time_to_point()` and the attainable-performance constants
  (`PLAYER_S_MAX`, `PLAYER_A_MAX`); positive when the defender can reach the
  arrival point first. No reaction-time term (`R/geometry.R`).
- **Passing window** (§7):
  $\texttt{window\_margin} = \max_{j \ne j^*} \max_{u} [\, uT - \tau_j(\mathbf{x}_0 + u(\mathbf{x}_1 - \mathbf{x}_0)) \,]$
  over $u \in \{0, 0.05, \ldots, 1\}$, assuming constant ball speed along the
  lane. On 23.5% of throws at least one help defender has a positive margin;
  that count (`window_n_pos`) is descriptive only.

Missing `dir` propagates (3 plays for `tta_nearest`, 28 for `window_margin`, of
16,646). Each feature moves completion in the expected direction: 81% when the
nearest defender is more than a second short of the arrival point against 33%
when they can beat the ball there by up to half a second; 79% when the best help
defender is more than a second short of the lane against 43–48% when one can
get there first.

**Results** (13,125 throws, out of fold):

| | $\Delta$ | 95% interval |
|---|---|---|
| Stage 4 − stage 3 (game) | **−0.0119** | [−0.0148, −0.0091] |
| Stage 4 − stage 3 (week) | −0.0119 | [−0.0158, −0.0083] |
| **Stage 4 − stage 2 (game)** | **−0.0563** | [−0.0622, −0.0503] |
| Stage 4 − `cp` (game) | −0.0470 | [−0.0530, −0.0409] |

In-sample deviance explained rises from 15.75% to 17.75%; `s(lev_angle)` edf
4.16, `s(tta_nearest)` edf 7.78, `s(window_margin)` edf 5.85. The week design
effect for stage 4 − stage 3 is 2.12 (game: 1.20): the time-based features' gain
varies more by week than separation's did.

**By depth** (game clusters):

| Depth (n) | Stage 3 log loss | Stage 4 − stage 3 | Share of stage 3 loss |
|---|---|---|---|
| 0–10 (7,953) | 0.5138 | −0.0095 [−0.0125, −0.0066] | 1.9% |
| 10–20 (3,495) | 0.6168 | −0.0172 [−0.0235, −0.0110] | 2.8% |
| 20+ (1,677) | 0.6216 | −0.0124 [−0.0217, −0.0030] | 2.0% |

The relative gain is largest at intermediate depth, not on deep throws as
expected; on deep throws stage 3's separation-by-depth interaction had already
captured part of what timing adds.

**Calibration:** overall slope 0.988 [0.945, 1.033]; on deep throws 0.86
[0.73, 0.996], slightly too spread out. **Reported, not corrected**: stage 4 is
the last stage, so adjusting it to its own out-of-fold results would be tuning
with nothing downstream to protect.

**The thesis comparison.** Stage 2 sees what `cp` sees, in the same model class
as stages 3 and 4, so stage 4 − stage 2 answers the question: coverage geometry
at the throw lowers out-of-fold log loss by 0.0563 nats [0.0503, 0.0622], more
than the 0.0554 that the play-by-play features gain over the base rate.
Separation accounts for 79% of it in the nested order, in which separation
enters first, and leverage, time to arrival, and the passing window for the
rest. Without an order, 36% is unique to separation, 21% unique to the geometry
terms, and 43% shared (§9.12). `cp` sits between stages 2 and 3.

### 9.10 Results on earlier populations

For the record; superseded by the sections above.

| Population | Throws | Stage 2 − stage 1 | Stage 2 − `cp` |
|---|---|---|---|
| All throws, charted air yards | 17,074 | −0.0621 [−0.0673, −0.0570] | — |
| Targeted receiver, charted air yards, constant QB hit | 16,643 | −0.0613 [−0.0666, −0.0561] | +0.0077 [+0.0058, +0.0096] |
| Targeted receiver, charted air yards, QB hit × depth | 16,643 | −0.0626 [−0.0678, −0.0573] | +0.0065 [+0.0048, +0.0083] |
| + beyond the line, tracking depth (stages 1–3 inputs) | 13,145 | −0.0553 [−0.0613, −0.0495] | +0.0094 [+0.0072, +0.0116] |
| **Final:** stages 1–4 inputs complete | 13,125 | −0.0554 [−0.0614, −0.0496] | +0.0093 [+0.0071, +0.0115] |

### 9.11 Robustness

`analysis/05_robustness.qmd` refits the stages under alternative measurement
and sample choices, with leave-one-week-out cross-validation and game-cluster
intervals as in §9.5. The baseline is scored from the predictions `09`
persisted (§9.4), the same ones notebook 03 reports; each check refits with the
same harness functions.

| Check | n | Stage 2 log loss | Stage 4 − stage 2 | Stage 3 − stage 2 | Stage 4 − stage 3 |
|---|---|---|---|---|---|
| Baseline | 13,125 | 0.5994 | −0.0563 [−0.0622, −0.0503] | −0.0444 [−0.0495, −0.0392] | −0.0119 [−0.0148, −0.0091] |
| R1 charted `air_yards` (and its zero indicator) | 13,125 | 0.5947 | −0.0546 [−0.0604, −0.0486] | −0.0438 [−0.0490, −0.0387] | −0.0108 [−0.0135, −0.0081] |
| R2 p90 motion constants (stage 4 only) | 13,125 | 0.5994 | −0.0557 [−0.0616, −0.0498] | (as baseline) | −0.0113 [−0.0142, −0.0085] |
| R3 without arrival fallbacks | 12,890 | 0.6011 | −0.0563 [−0.0624, −0.0501] | −0.0431 [−0.0482, −0.0379] | −0.0132 [−0.0164, −0.0100] |
| R4 without kinematic defects | 12,778 | 0.6011 | −0.0562 [−0.0621, −0.0502] | −0.0447 [−0.0499, −0.0395] | −0.0115 [−0.0143, −0.0086] |
| R5 without QB-hit plays | 11,927 | 0.5920 | −0.0561 [−0.0626, −0.0496] | −0.0443 [−0.0501, −0.0386] | −0.0118 [−0.0147, −0.0089] |
| R6 without `at_window_edge` (outcome-selected) | 11,141 | 0.5947 | −0.0607 [−0.0672, −0.0542] | −0.0493 [−0.0552, −0.0433] | −0.0115 [−0.0144, −0.0084] |

**The thesis comparison is robust.** Across R1–R5, stage 4 − stage 2 lies
between −0.0546 and −0.0563, every interval far from zero and overlapping the
baseline.

- **R1.** Charted `air_yards` gives a slightly *stronger* stage 2 (0.5947
  against 0.5994): the charter records the catch or target point, which the
  last in-flight frame approximates. The geometry's gain over that baseline is
  essentially unchanged.
- **R2.** The p90 constants (`PLAYER_S_MAX_P90` 9.98 yd/s, `PLAYER_A_MAX_P90`
  6.50 yd/s²) make stage 4 slightly *worse* than the median ones, by 0.0006
  [0.0003, 0.0010] nats, and leave the gain unchanged.
- **R3–R5.** Dropping arrival fallbacks (§6.6), plays with defects outside the
  measurement window (§4.2), or QB-hit plays (§7, with the QB-hit term removed)
  changes nothing.
- **R6.** Larger gain, but these are mostly completions with a long carry, so
  excluding them selects on the outcome (base rate 0.638 → 0.627). Reported
  for completeness, not as evidence.

Implementation: `07` writes `tta_nearest_p90` and `window_margin_p90` from the
same function as the main timing features, and `08` carries them, with charted
`air_yards` and `yards_to_go`, into `model_frame.parquet`.

### 9.12 Term contributions

`analysis/06_term_contributions.qmd` refits stage 4 without each tracking term,
or block of terms, on the same leave-one-week-out folds, and reports the rise
in out-of-fold log loss with a game-cluster interval: the term's contribution
given all the others. Diagnostic only; no spec changed.

| Dropped from stage 4 | Rise in log loss |
|---|---|
| separation, `s(sep_throw)` + `ti(sep_throw, depth_arr)` | 0.0165 [0.0132, 0.0199] |
| time to arrival, `s(tta_nearest)` | 0.0079 [0.0057, 0.0100] |
| closing speed, `s(closing_throw)` | 0.0077 [0.0055, 0.0098] |
| passing window, `s(window_margin)` | 0.0030 [0.0017, 0.0043] |
| separation × depth, `ti(sep_throw, depth_arr)` alone | 0.0011 [0.0001, 0.0021] |
| leverage angle, `s(lev_angle)` | 0.0008 [0.0001, 0.0015] |
| **separation block** (the stage 3 terms) | 0.0204 [0.0167, 0.0242] |
| **geometry block** (the stage 4 terms; = stage 4 − stage 3, §9.9) | 0.0119 [0.0091, 0.0148] |

Separation and its depth interaction are dropped together because `ti()` is
built to sit alongside its main effects. The geometry-block row reproduces
§9.9 exactly, which checks the refit harness.

**Every term earns its place.** No interval includes zero, so none is a
removal candidate. Leverage angle and the separation-by-depth interaction are
the weakest, both with lower bounds at 0.0001; the interaction is kept for the
deep-throw calibration it was added for (§9.8), and leverage has the lowest
concurvity of any tracking term (worst 0.39), so it carries little but carries
something the others do not.

**The 79% attribution in §9.9 depends on order.** It credits separation with
all of stage 3 − stage 2 because separation enters first. Decomposing stage 4 −
stage 2 (0.0563) without an order:

| Part | Nats | Share |
|---|---|---|
| unique to separation (separation block) | 0.0204 | 36% |
| unique to the geometry terms (geometry block) | 0.0119 | 21% |
| shared: either block recovers it without the other | 0.0240 | 43% |

The shared part is 0.0444 − 0.0204, stage 3's gain over stage 2 less what
separation adds once the geometry terms are present. Separation and the timing
features are partly the same information: the nearest defender's time margin
is largely its distance expressed in time.

**The three geometry terms are nearly additive**: their drop-one rises sum to
0.0117 against the block's 0.0119. The overlap is between blocks, not within
the geometry block.

**Concurvity** (stage 4 fit on all rows, `worst`): no tracking smooth exceeds
0.67 against all other terms (`s(tta_nearest)`), so nothing is redundant.
The largest pairwise values are `s(sep_throw)` with its interaction (0.43, by
construction), `s(window_margin)` with `s(depth_arr)` (0.40: longer throws give
help defenders more time), `s(sep_throw)` with `s(tta_nearest)` (0.38), and
`s(closing_throw)` with `s(tta_nearest)` (0.35).

### 9.13 Lateral location: candidate features

Candidates to replace charted `pass_location` in stage 2, as `depth_arr`
replaced charted `air_yards` (§9.3). Derived by `prepare_model_frame()` from
`arrival.parquet`, carried by `08`, and not yet in `MODEL_SPECS`:

- `lat_arr` $= y_{\text{arr}} - y_{\text{throw}}$: the arrival point's lateral
  offset from the release point. Positive is toward the passer's left
  (standardized coordinates face $+x$, and $y$ increases to the left).
- `sideline_arr` $= \min(y_{\text{arr}},\ 53.\overline{3} - y_{\text{arr}})$:
  distance from the arrival point to the nearer sideline, negative when the
  ball arrives out of bounds.

Like `depth_arr`, both use where the ball arrived as the measure of where it
was thrown, so they inherit that assumption (§6.9). Rebuilding `08` left every
existing column and the funnel identical, and the persisted fits stayed valid
(§9.4). No missing values.

**Sign validated against charted `pass_location`:**

| Charted | Plays | Median `lat_arr` | Share with `lat_arr` > 0 | 10th–90th percentile | Median `sideline_arr` | Complete |
|---|---|---|---|---|---|---|
| left | 4,592 | +15.3 | 99.2% | +6.8 to +23.5 | 9.3 | 62.3% |
| middle | 3,593 | +0.0 | 50.2% | −6.1 to +6.6 | 22.8 | 69.0% |
| right | 4,940 | −14.3 | 1.9% | −22.9 to −5.5 | 8.7 | 61.3% |

The charted location is the throw's direction relative to the passer, with
"middle" about ±6 yd of the release point, not a third of the field.
`lat_arr` is therefore its continuous version; `sideline_arr` measures
something the charted variable does not, the field boundary. The two are
correlated ($r(|\texttt{lat\_arr}|, \texttt{sideline\_arr}) = -0.86$).

**Descriptively**, completion is flat at 67–70% beyond 6 yd from the sideline
and falls inside it: 58.8% at 3–6 yd, 45.2% at 0–3 yd, and 21.1% for the 204
arrivals at or beyond the sideline (203 strictly out of bounds). By lateral
offset it is flat to 20 yd (65–69%) and 49.3% beyond. Both are confounded with
depth: throws within 3 yd of the sideline have median depth 15.3 yd against
5.4–6.2 yd beyond 6 yd, so the model, not these tables, has to separate them.

**Open: out-of-bounds arrivals.** A ball arriving beyond the sideline is
largely a missed throw, so negative `sideline_arr` partly records throw
accuracy, which is decided after the release. `depth_arr` has the same property
for overthrows, but the sideline makes it sharper. To be settled before
adoption, by comparing `sideline_arr` with `pmax(sideline_arr, 0)`.

**Candidate comparison** (`analysis/07_lateral_location.qmd`; same folds,
game-cluster intervals; expectations recorded in the notebook before fitting).
Each candidate replaces `pass_location` in stage 2, and in stage 4 where
stated:

| Candidate | Out-of-fold log loss | Against current stage 2 |
|---|---|---|
| current stage 2 (charted `pass_location`) | 0.5994 | — |
| A: `s(lat_arr)` | 0.5995 | +0.0001 [−0.0008, 0.0011] |
| B: A + `s(sideline_arr)` | 0.5937 | −0.0057 [−0.0077, −0.0037] |
| C: A + `s(pmax(sideline_arr, 0))` | 0.5946 | −0.0048 [−0.0066, −0.0031] |

- **The lateral offset adds nothing over the charted variable**, as expected:
  they are the same information. In B it fits as a flat line (edf 1.01, $p =
  0.56$).
- **Sideline distance carries the location effect.** It adds 0.0058
  [0.0040, 0.0077] beyond the lateral offset. The smooth is flat beyond about
  4 yd from the sideline and falls steeply inside it, to about −1 on the logit
  scale at the line and below it out of bounds (edf 7.56). The charted
  "middle" effect (+0.257, §9.3) was largely this: middle throws are far from
  the sideline. Concurvity of `s(lat_arr)` with `s(sideline_arr)` is 0.77.
- **Out-of-bounds distance is worth 0.0009 [0.0002, 0.0014]** (B against C),
  about a sixth of B's gain. That part is throw accuracy.
- **In stage 4**, B improves on the current stage 4 by 0.0046 [0.0026,
  0.0065], so the tracking features had not been recovering the sideline.
- **The tracking gain barely moves**: stage 4 − stage 2 is −0.0552 [−0.0610,
  −0.0493] on B and −0.0553 [−0.0611, −0.0495] on C, against −0.0563.
- **The passing window did not lose its contribution**, contrary to the
  expectation: dropping `s(window_margin)` costs 0.0034 [0.0020, 0.0048] on B
  against 0.0030 [0.0017, 0.0043] on the current stage 4.
- **Calibration** (stage 2, point estimates): unchanged overall (slope 0.987);
  better by depth. Slopes move from 0.935 to 0.966 (B) and 0.973 (C) at 0–10
  yd, 1.161 to 1.057 (both) at 10–20 yd, and 0.837 to 0.888 (B) and 0.860 (C)
  at 20+ yd.

**Round two.** Two revisions, argued before fitting:

- **`lat_arr` is dropped.** It adds nothing over the charted variable and is
  flat once sideline distance is present.
- **`pass_location` becomes binary**, middle or not (`pass_middle`), as in
  nflverse `cp`. There is no football argument for left and right to differ;
  they are not distinguishable (§9.3), and the signed lateral offset fit as a
  flat line.
- **Sideline distance is measured at the targeted receiver** at the arrival
  frame (`sideline_rec`), not at the ball, so that a ball sailing out of bounds,
  a missed throw decided after the release, does not enter as location. The
  arrival frame rather than the throw frame because the boundary acts where
  the catch is made, and because `depth_arr` is measured there too. The
  receiver's tracked position is out of bounds on 109 plays (16.5% complete)
  against 203 balls; the sensor is on the shoulder pads, and some receivers
  drift with an errant throw. Receiver and ball sideline distances correlate
  at 0.99 and differ almost only at the boundary.

| Candidate | Out-of-fold log loss | Against current stage 2 |
|---|---|---|
| E: `pass_middle` for `pass_location` | 0.5994 | 0.0000 [−0.0002, 0.0002] |
| F: E + `s(sideline_rec)` | 0.5946 | −0.0048 [−0.0065, −0.0032] |
| G: E + `s(pmax(sideline_rec, 0))` | 0.5949 | −0.0044 [−0.0060, −0.0029] |

- **The binary coding loses nothing.** In F, middle is +0.177 (SE 0.070) on
  the logit scale beyond sideline distance, so it carries something the
  boundary does not.
- **Receiver and clamped ball measures predict equally** (F against C: 0.0000
  [−0.0009, 0.0009]). The receiver's out-of-bounds tail is worth 0.0004
  [0.0001, 0.0006] (F against G), under half the ball's.
- **The shape matches the ball version**: flat beyond about 4 yd, about −1.2
  on the logit scale at the line (edf 7.21).
- **Stage 4 on F** improves on the current stage 4 by 0.0043 [0.0027,
  0.0059]; the tracking gain is −0.0558 [−0.0616, −0.0500].
- **Calibration** (stage 2, point estimates): overall slope 0.987, unchanged.
  By depth, F moves the slope from 0.935 to 0.963 at 0–10 yd, 1.161 to 1.055
  at 10–20 yd, and 0.837 to 0.910 at 20+ yd, the best deep-throw slope of any
  candidate.

Not yet adopted.

## 10. Known technical constraints

- Arrow `Dataset` objects do not survive knitr cache serialization. Caching must
  stay disabled in any notebook holding a lazy Arrow dataset.
- Quarto's default `execute-dir: file` starts the kernel in the notebook's
  subdirectory, which prevents `.Rprofile` from loading and renv from
  activating. Fixed via `execute-dir: project` in `_quarto.yml`.
- Helper files in `R/` define functions; they do not attach packages.
  `library()` calls belong in notebooks and scripts. (`R/viz.R` is the
  exception.) `MODEL_SPECS` uses bare `s()`, so `mgcv` must be attached before
  fitting.
- Chunk labels prefixed `fig-` trigger Quarto's cross-referencing system and
  produce unwanted "Figure" captions. Avoid the prefix.
- A raw `{=html}` CSS block placed before the first slide heading in a Revealjs
  deck renders as a blank slide. CSS belongs in `theme/capstone.scss` under
  `/*-- scss:rules --*/`, or in the YAML `include-in-header`.
- Arrow will not push down `lag()`, so frame-to-frame differencing runs on a
  collected sample rather than the full dataset.
- Arrow's `quantile()` is a t-digest approximation and is the wrong tool for
  extreme-tail work. Tail quantiles are computed from exact bin counts; extrema
  from a separate scalar aggregate.
- Ball rows are roughly one-fifteenth of the tracking data (1.25M of 18.3M rows),
  so the whole season of them collects into memory comfortably. Player rows do
  not.
- `median()` and `quantile()` without `na.rm = TRUE` return `NA` from a single
  missing value. Ball `s` and `dis` each have exactly one (§2).
- Object attributes do not survive a Parquet round trip. `nflverse_timestamp`
  has to be captured at download time or lost (§8.1).
- **A comparison column should carry a label, not `NA`.** `NA == "x"` is `NA`,
  `filter()` drops `NA` rows, and a sum over an `NA`-indexed subset returns
  `NA` — so an `NA` category silently disappears from a disagreement count.
  `nflverse_outcome_class()` returns `"no pass recorded"` for this reason; an
  earlier version returned `NA` and hid the 627-play block of §8.3.
- **`game_clock` in `plays.parquet` is mis-parsed.** The source's MM:SS clock is
  read as HH:MM, so 14:25 is stored as 51,900 seconds. Divide by 60 to recover
  seconds remaining in the quarter, or re-parse in `02`, before using it.
- `paired_delta()` sets its seed through `withr::with_seed()`, leaving the
  global RNG untouched.
- **Arrow returns ALTREP vectors**, factor levels included, and their
  serialized form depends on whether they have been materialized. A hash of
  columns read from Parquet can therefore differ between sessions with the
  data unchanged. `model_input_hash()` rebuilds each column as an ordinary
  vector before hashing.
- `gam.check()` / `k.check()` output varies between renders: with more than
  5,000 rows the k-index is computed on a random subsample and its p-value by
  permutation, neither seeded. Notebook 03 quotes only `edf` and `k'` from it,
  which are deterministic.
- **gganimate under knitr reads the chunk's figure options as device
  defaults**: `units = "in"`, so a `width` meant as pixels becomes inches and
  the render appears to hang; and `res` equal to the chunk dpi, doubled for
  retina (192), which draws markers and text about 2.7 times larger than a
  render outside knitr (72). `render_play()` passes `units = "px"` and
  `res = 72` explicitly, so output is the same in and out of a notebook. GIFs need `gifski` (recorded in `renv.lock`, as is
  `av` for mp4).
- **Each `gt_theme_538()` table embeds its own copy of the Google fonts** under
  `embed-resources: true`, so notebooks with many tables render to HTML files of
  80+ MB. Harmless, since rendered HTML is not committed.
