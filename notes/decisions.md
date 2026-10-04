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
| `06_build_throw_frame.R` | planned | Applies `R/arrival.R` at season scale; emits the throw-frame slice. |
| `07_build_features.R` | planned | Throw-frame coverage features. |
| `08_build_model_frame.R` | planned | Model-frame assembly, question-level population filters with their own funnel, leak assertions. |

| Helper / notebook | Owns |
|---|---|
| `R/geometry.R` | Componentwise vector geometry. Functions only, no grouping. |
| `R/arrival.R` | Kinematic arrival detection — a grouped sequence reduction, so it does not fit `geometry.R`'s contract. |
| `R/pbp.R` | The nflverse bridge: key casts, column vocabulary, leak assertion, join-validation functions. No network access. |
| `R/evaluate.R` | Model frame preparation, model specs, cross-validation harness, scoring (§9). |
| `analysis/01_eda.qmd` | Data audit and sample-definition report. Writes nothing. |
| `analysis/02_arrival_anchor.qmd` | Arrival-anchor investigation. Writes nothing. |
| `analysis/03_model_baseline.qmd` | Baseline models and scoring. Writes nothing to `data/`; assembles the model frame inline until `08` exists. |

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
plays fail it) and appears in no rule — verified for both `SCOPED_FLAGS` and
`CONSERVATIVE_FLAGS`. It must not enter the `08` funnel. `FLAG_GROUP` still
labels it `"population"`; relabeling it is pending (§7). Arrival is derived, not
read.

### 4.9 Adopted: a targeted receiver is part of the population

**Decision.** The modeling population is thrown passes with a targeted
receiver, matching nflverse, which computes `cp` only when a receiver is named
(§8.4). Throwaways, spikes, intentional grounding, and passes with no
identifiable target are out of scope: the question is the completion
probability of a pass to a receiver, and these have none. Applied in `08`
(§0); until `08` exists, applied inline in `analysis/03_model_baseline.qmd`
§1.2, which reads `receiver_player_name` from the nflverse mirror because
`pbp.parquet` does not carry it yet.

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

**Implementation.** `keep_target` currently conflates "named" and "tracked".
`08` splits it into a population flag (receiver named) and a quality flag
(target tracked).

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
`keep_any_throw`. Separate spike and scramble filters in `08` would remove
zero plays and serve only as tripwires.

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
§6.1, which is full-season. Re-validate at season scale once `06` runs; the
checklist is §6.8.

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
The passing-window corridor is 2–3 yd wide, so a p90 error of 8 yd is
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
- *Class similarity* — median $d_{\text{arr}}$ of $0.690$ yd (C) and $1.16$ yd
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

$\approx 2.8\%$ of plays never reach flight speed inside the window
(`used_fallback`) and fall back to closest approach. These are batted balls and
soft flips with very short lanes; most are expected to exit at the
beyond-the-LOS filter.

### 6.7 Two things `d_arr` must never be used for

**Not a model feature.** A ball ending up $0.12$ yd from the receiver *is* the
catch. `d_arr` or `d_min` in the feature set would drive log loss down while
saying nothing about coverage geometry.

**Not a filter.** A pass that never got near its target is a real play with real
coverage geometry, and almost by definition an incompletion. Excluding on
$d_{\text{arr}}$ would reintroduce the selection on outcome that §6.1 rejected.
Sensitivity to `used_fallback` and `at_window_edge` is checked at the model
stage instead.

### 6.8 Full-season checks to re-run once `06` exists

Before any feature work. The week-1 numbers above are the benchmark.

1. **Class similarity** of $d_{\text{arr}}$, all 17 weeks.
2. **Speed equalization** by 2-yd depth bin, all 17 weeks.
3. **Bounce check**, since a rarer artifact may only appear at 17× the sample.
4. **Three plays rendered with `render_play()`** — one completion, one
   incompletion, one interception — stepped to $f_{\text{arr}}$.
5. **External validation against `air_yards`.** Compare
   $x_{\text{arr}} - \texttt{los\_x}$ against nflverse `air_yards` (§8), an
   independently charted measurement of the same quantity. Also validates the
   sign convention and settles the beyond-the-LOS threshold (§7).

---

## 7. Open items

### Settled

**Research question.** Completion probability at the throw, predicted from
tracking-derived coverage geometry, on passes thrown beyond the line of
scrimmage to a tracked targeted receiver (§4.9). Separation is a feature of
that model rather than a separate question. Candidate geometry: receiver
separation and closing speed (stage 3); leverage, the passing-window corridor,
and time-to-arrival (stage 4).

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
  Its stage 2 coefficient is $-0.88$ (§9.3).
- **Targeted receiver as population** (§4.9). This also closes two earlier
  checks: throwaways and spikes carry no BDB target (all 407 untargeted throws
  in the analytic sample; all 75 spikes), so no separate pbp-derived throwaway
  flag is needed.
- **Spikes and scrambles** are already out of the base sample (§4.9).
- **Four untargeted interceptions** reviewed on video and excluded with the
  other untargeted throws (§4.9).
- **`keep_arrival`** appears in no rule (§4.8).
- **Resampling unit for $\Delta$ log loss intervals: game** (§9.5).
- **Calibration method** (§9.6) and **`cp` benchmark method** (§9.7): fixed
  external predictions, no recalibration.

### Open

- **Beyond-the-LOS threshold.** Of the 17,343 spine plays with charted
  `air_yards`, **20.9% are at or below zero** — 2,529 negative and **1,093 at
  exactly zero**. The threshold is to be set on the continuous tracking-derived
  throw distance from `06` and validated against `air_yards` (§6.8). Provisional
  cost: roughly a fifth of the sample. Consequence for stage 2: the filter
  removes most or all `air_yards == 0` plays, leaving `air_yards_zero` constant
  or nearly so; it must then leave the spec.
- **Penalty-nullified plays.** All 633 are currently excluded by `keep_los`
  (§4.7), not by decision. Retaining them, or running the `keep_official_play`
  sensitivity, first requires recovering `los_x` for them, e.g. from the ball
  position at the snap.
- **Corridor width**: 2 yd or 3 yd.
- **Robustness**: refit with `PLAYER_S_MAX` at $9.22$ and $9.98$ and report that
  log loss barely moves.
- **Man/zone** — whether the binary earns a place in the model, given §5 and
  the 13-game denominator.
- **QB kinematic state** — listed among the geometry features in earlier
  framing but not assigned to stage 3 or 4.
- **`FLAG_GROUP` relabel** for `keep_arrival` (§4.8).
- **Depth control.** The tracking-derived throw distance replaces `air_yards`
  in stage 2 once `06` exists; `air_yards` becomes a robustness refit (§9.3).
- **Stage 2 on deep throws.** Calibration slope 0.62 within 20+ air yards
  (§9.6). Whether stage 2 should gain a depth interaction, given that this
  changes the baseline geometry is measured against. Until decided, stage 3–4
  results are reported by depth.
- **`receiver_player_name` in `pbp.parquet`.** Add it to `PBP_COLS` and re-run
  `05` (a rebuild of `data/processed/pbp.parquet`, no network) so `08` does not
  read the interim mirror.

### Play types measurable but not yet filtered

`SAMPLE_RULE` is question-agnostic by design. Status of play types that may be
inappropriate for this question:

| Play type | Status |
|---|---|
| QB spikes | Already out of the base sample (§4.9) |
| Throwaways, intentional grounding, untargeted passes | Out via the targeted-receiver population (§4.9) |
| Penalty-nullified plays | Already out via `keep_los` (§4.7); open above |
| Screens and other passes behind the LOS | Beyond-the-LOS filter (open) |
| Batted or tipped passes at the line | Not yet flagged |
| Hail Marys | Not yet flagged |
| Goal-line plays with extra linemen | Not yet flagged |
| Two-point conversions | Not yet checked |

### Feature state

`R/geometry.R`, `R/arrival.R`, `R/pbp.R`, `R/evaluate.R`, and scripts 01–05
exist; `pbp.parquet` is built. Stages 1 and 2 are fit and scored (§9). No
tracking feature table exists yet. `06` is next after the scoring work: apply
`detect_arrival()` at season scale and emit the throw-frame slice (all tracked
players at $f_{\text{throw}}$ and at $f_{\text{arr}}$).

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

## 9. Baseline models and evaluation

Implemented in `R/evaluate.R`, reported in `analysis/03_model_baseline.qmd`.
**Provisional population:** the model frame is assembled in the notebook, with
the targeted-receiver filter (§4.9) applied inline. The beyond-the-LOS filter
is not yet applied, so every number in this section will change when it is.

### 9.1 Response and scoring population

`complete = 1` for C; I and IN are 0, which matches nflverse `cp` and makes the
benchmark comparable.

The model frame joins `analytic_sample.parquet`, `number_of_pass_rushers` from
`plays.parquet`, `pbp.parquet`, and `receiver_player_name` from the nflverse
mirror, restricted to `pass_result` in {C, I, IN}:

| Step | Dropped | Remaining | Complete (kept) | Complete (dropped) |
|---|---|---|---|---|
| thrown passes | — | 17,077 | 65.3% | — |
| nflverse receiver named (population) | 409 | 16,668 | 66.9% | 0.2% |
| targeted receiver tracked (quality) | 25 | 16,643 | 66.9% | 84.0% |

No play in the population lacks a variable any spec requires. Scoring
population: **16,643 throws, base rate 0.668509**, every one carrying `cp`.
(Before §4.9, 3 of 17,077 throws lacked `air_yards`; none passes the filter.)

**Assert, don't filter.** `assert_complete()` fails on any NA in any spec
variable rather than dropping rows, and every fit uses `na.action = na.fail`:
`glm()` and `gam()` would otherwise drop rows per stage and score stages on
different populations. The population requirement is the union across all
specs.

### 9.2 Derived predictors

- **Rare factor levels** (fewer than 100 plays) are lumped into `"other"` so no
  level is absent from a training fold. Affects nothing in the current spec;
  written when `offense_formation` was in the model (WILDCAT: 31 plays, 17 in
  week 14). `NA` stays `NA`.
- **`number_of_pass_rushers` clamped to [2, 7].** On the 17,077 throws before
  §4.9 this moved 117 plays (values 0: 16, 1: 72, 8: 28, 9: 1). Zero rushers on
  a pass play is a charting artifact, and sparse tails would be extrapolated in
  the folds that hold them out.
- **`dist_to_sticks = air_yards - yards_to_go`** replaces `yards_to_go`. Additive
  smooths in `air_yards` and `yards_to_go` cannot represent whether the throw
  reaches the line to gain; all three together are linearly dependent.
- **`air_yards_zero`** flags throws at exactly zero air yards (923 in the
  population), a point mass a penalized smooth cannot capture.
- **`home`**: offense is the home team.

### 9.3 Stage specifications

Stage 1: intercept-only `glm()`.

Stage 2 (`mgcv::gam()`, REML):
`s(air_yards) + s(dist_to_sticks) + s(los_x) + s(number_of_pass_rushers, k = 5)
+ air_yards_zero + down + pass_location + shotgun + home + qb_hit`.

**The nesting is the argument.** Stage 2 already knows the situation and the
throw's depth, so stages 3 and 4 must earn their improvement on coverage
information alone. Every term removed from stage 2 makes the headline delta
larger and less defensible, so **baseline terms are cut by argument, never by
in-sample $p$-value.**

Stage 2 follows `cp`'s feature set where BDB supports it. Departures:

- **Three pass locations**, not middle/not-middle. Against left, middle is
  $+0.177$ (SE 0.047) and right $-0.058$ (SE 0.040, $p = 0.15$). Middle differs
  from both sides. Left and right differed by about 3.6 SE on the population
  before §4.9 and are not distinguishable on this one; the three-level coding is
  kept rather than revised on a $p$-value.
- **`number_of_pass_rushers` added** ($\chi^2 = 40.0$, edf 1.01): a defensive
  control, so stage 3–4 features cannot be said to recapture rushers versus
  droppers.
- **`air_yards_zero` included**: $-0.67$ (SE 0.084) against an intercept of
  $1.08$, about half the odds of completion. When it was added during
  specification (on the population before §4.9), `s(air_yards)` edf rose from
  4.37 to 7.67 and deviance explained improved on a smaller model.
- `roof` and era omitted: era is meaningless in one season, and `roof` is not
  in `PBP_COLS`.

Tested and dropped (during specification, on the population before §4.9):

- **`offense_formation`**: describes scheme rather than difficulty, and is
  aliased with `shotgun` (an empty-backfield snap is essentially always from
  shotgun), inflating standard errors from about 0.04 to about 0.35.
- **`defenders_in_the_box`** and **`score_differential`**: edf about 1.00 and
  $p > 0.05$, and droppable by argument — the box count is vendor-charted with
  implausible tail values, and the blowout mechanism behind score differential
  is absent from the data.

**Retained despite being weak:** `s(dist_to_sticks)`, edf 1.03, $p = 0.07$. It
is the model's only `yards_to_go` information.

Other stage 2 effects: `shotgun` $-0.258$ (SE 0.049) — conditional on depth,
shotgun passes complete less often; `qb_hit` $-0.78$ (SE 0.060), the largest
parametric effect; third down $-0.16$ (SE 0.048). `s(air_yards)` edf 7.09.
Deviance explained **9.90%** in-sample.

`air_yards` is provisional because it is charted, not measured. Once `06`
exists, the tracking-derived throw distance replaces it and `air_yards` becomes
a robustness refit.

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
| $H(\bar y)$, $\bar y = 0.668509$ | 0.6352 |
| Stage 1 | 0.6353 (+0.00011) |
| Stage 2 | 0.5740 |
| nflverse `cp` | 0.5663 |

**Paired $\Delta$ log loss** (`paired_delta()`): the mean of per-play
differences, with a cluster bootstrap percentile interval (10,000 draws) that
holds the out-of-fold predictions fixed.

**Resampling unit: game** (253 clusters). Week (17 clusters) matches the folds
but is too few for a percentile bootstrap, and is reported as a sensitivity
check.

| Stage 2 − stage 1 | $\Delta$ | 95% interval | SE (bootstrap) | SE (analytic) | SE (iid) | Design effect |
|---|---|---|---|---|---|---|
| game | −0.0613 | [−0.0666, −0.0561] | 0.00267 | 0.00266 | 0.00265 | 1.01 |
| week | −0.0613 | [−0.0660, −0.0567] | 0.00239 | 0.00247 | 0.00265 | 0.87 |

Clustering is immaterial for this comparison: game-level factors affect both
stages' losses alike and cancel in the paired difference. The week design
effect is within the noise of a 17-cluster estimate. Game clustering is kept
because stage 3–4 gains may concentrate by game. (On the population before
§4.9, 17,074 throws: $-0.0621$ [$-0.0673$, $-0.0570$].)

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
Figures: `figs/week06/calibration.png`, `calibration_by_air_yards.png`.

**Subgroups:** air-yards buckets with edges fixed in advance — $\le 0$, 1–9,
10–19, 20+ (`air_yards_bucket()`). Separation buckets follow with stage 3.

| | CITL | Slope |
|---|---|---|
| Stage 2 | 0.000 [−0.008, 0.008] | 0.990 [0.944, 1.039] |
| `cp` | 0.005 [−0.003, 0.013] | 1.022 [0.979, 1.067] |

| Air yards (n) | Stage 2 slope | `cp` slope |
|---|---|---|
| $\le 0$ (3,371) | 0.96 [0.79, 1.13] | 0.97 [0.85, 1.10] |
| 1–9 (7,679) | 0.98 [0.87, 1.08] | 1.01 [0.91, 1.11] |
| 10–19 (3,601) | 0.97 [0.81, 1.12] | 1.01 [0.88, 1.15] |
| 20+ (1,992) | **0.62 [0.41, 0.84]** | 1.05 [0.79, 1.32] |

CITL intervals contain zero in every bucket for both. **Stage 2 is too extreme
within deep throws**: its additive terms move predictions among deep throws at
the strength they have across all throws, and the outcomes do not support that
spread. `cp`, which can represent interactions, does not show it. Recorded as an
open question (§7) rather than fixed, because adding a depth interaction would
change the baseline that geometry is measured against. The stage 3–4
comparison is to be reported by depth as well as overall.

### 9.7 The `cp` benchmark

`cp` is scored as a fixed external set of predictions on the same 16,643 rows;
it is not refit or recalibrated.

| Comparison (game clusters) | $\Delta$ | 95% interval |
|---|---|---|
| Stage 2 − `cp` | +0.0077 | [+0.0058, +0.0096] |
| `cp` − stage 1 | −0.0691 | [−0.0743, −0.0638] |

`cp` beats stage 2 by 0.0077 nats; stage 2 captures 89% of `cp`'s improvement
over the base rate. Both are calibrated overall, so the gap is in
discrimination. Plausible sources, not separable here: `cp`'s model class
represents interactions (consistent with the deep-throw finding in §9.6), it is
trained on far more plays, and 2018 is partly in its training data. The gap is
the reference point for stages 3 and 4.

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
