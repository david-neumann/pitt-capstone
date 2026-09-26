# Decisions log

NFL Big Data Bowl 2021 (2018 season) — STAT 1961 capstone.

This log is the source for the Methods section of the December report. Every
entry is a decision, not a finding: something that could reasonably have gone
another way, with the counts attached and the cost stated. Findings that
constrain decisions are recorded under **Verified assumptions** and **Structural
constraints**.

Counts current as of the week-4 rebuild unless marked otherwise.

Section numbers are cited from code comments (`R/arrival.R`,
`analysis/02_arrival_anchor.qmd` reference §6 and §7). Do not renumber §6 or §7
without updating those.

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

**Feature and external-data layers, added in weeks 5–6.** Measurement of derived
quantities and the ingest of outside data extend the same boundary rather than
breaking it:

| File | Owns |
|---|---|
| `R/geometry.R` | Componentwise vector geometry. Functions only, no grouping. |
| `R/arrival.R` | Kinematic arrival detection — a grouped sequence reduction, so it does not fit `geometry.R`'s contract. |
| `R/pbp.R` | The nflverse bridge: key casts, column vocabulary, leak assertion, join-validation functions. No network access. |
| `scripts/05_join_pbp.R` | Pulls and mirrors nflverse play-by-play; emits `pbp.parquet` on the plays keys. Measured facts only. |
| `scripts/06_build_throw_frame.R` | Applies `R/arrival.R` at season scale; emits the throw-frame slice. |
| `analysis/02_arrival_anchor.qmd` | Reports the arrival-anchor investigation. Writes nothing. |

`R/arrival.R` exists as a helper rather than living inside `06` because the
notebook is a second caller, and duplicated measurement logic goes stale. The
same reasoning moved `require_cols()` out of `02_build_canonical.R` into
`R/utils.R` once `05` became a second caller.

**`05` makes no exclusions.** `qb_spike` is a fact; `keep_not_spike` is a
decision and belongs in `R/sample_rules.R`, applied by
`scripts/08_build_model_frame.R` and reported in the question-level funnel.

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
`gameId` (e.g. 2018090600) fits inside the `int32` ceiling. The same cast is
what makes the nflverse bridge work (§8.1), where `old_game_id` arrives as
character and `play_id` as double.

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
assertions in `03_build_play_index.R` rather than a table in the notebook. The
nflverse join is verified separately and on different grounds (§8.2), because a
key-level check cannot detect keys matched to the wrong plays.

**Ball kinematics are populated.** `s` and `dis` on ball rows are each missing on
exactly 1 of 1,247,642 rows. This went unnoticed until week 5 because the
kinematic defect scan in `03` filters `!is_ball`, so a ball travelling at 2
yd/frame was never a candidate for flagging. It is the discriminating column in
§6.

---

## 3. Structural constraints

Not decisions — facts that bound what questions are askable.

**Not all 22 players are tracked per play.** Offensive and defensive linemen are
excluded. This rules out any analysis of pass rush, blocking, or pocket
integrity. Observed mean is $263{,}173 / 19{,}239 \approx 13.7$ tracked players
per play, the excess coming from goal-line packages and the exceptions below.

**The pre-snap window is fixed at 10 frames — exactly $1.0$ s — on over 99% of
plays.** `p05`, `p50`, and `p95` of `frames_pre_snap` coincide, so this is a
structural constant rather than a distribution. Every pre-snap feature
(alignment, leverage, motion detection) has $1.0$ s and no more, and no amount
of filtering buys extra.

**Coverage labels exist for week 1 only.** This is the binding constraint on any
coverage-framed question and the reason coverage classification was scoped out
(§7).

**BDB ships 253 of the season's 256 games, and all three omissions are in week
1.** Established by the game-set comparison against nflverse (§8.1). Week 1 is
therefore **13 games and 1,034 plays**, not 16 games. Two consequences worth
stating rather than discovering later:

- The week-1 coverage labels cover 13 games, so the coverage-conditional
  framing is thinner than "one week of 16" implies. The shortfall is a data
  omission, not label attrition.
- The arrival-anchor prototyping sample (§6, $n = 890$) is 13 games. This does
  not affect any conclusion, since the definition rests on the full-season
  re-run, but it is the correct description of the prototype.

Games per week otherwise ranges 13–16 with byes.

**Kinematic defects cluster by week.** 1,396 defective rows total. The
clustering is a collection artifact rather than noise, which is what justifies
treating them as a data-quality exclusion rather than modeling them.

**There is no $z$ coordinate.** Ball height is not recorded, so ground contact,
throw trajectory, and contested-catch height are all invisible. This is why
arrival has to be inferred from horizontal displacement (§6) rather than
detected directly.

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

Note that `MAX_DIS` acquires a second, deliberate use in §6 as the ball
flight/carry boundary. The coupling is by argument, not coincidence, and is
documented at both ends.

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

**This was the only non-ignorable exclusion in the pipeline** until §6 found a
second and larger one in a candidate filter, and §8.3 found a third in the
benchmark's own scoring population. It accounts for roughly a quarter of all
attrition and it is selected on outcome. Any outcome model fit on the retained
sample carries that selection, and the Methods section must state its direction
and magnitude rather than reporting the exclusion as routine.

A related check: the thrown-pass subset of zero-route plays is enriched in
incompletions at a similar rate. Whether these are one block or two is tested in
notebook §3.6 (`route-los-overlap`); if `keep_los` already removes them, no
separate exclusion is needed.

**The pattern, stated once as a working principle.** Selection on outcome is the
central data hazard in this project. Three separate mechanisms have now produced
it — a metadata gap, a candidate measurement rule, and a third party's model
availability — so any exclusion rule is checked for differential rates by
completion status *before* adoption, not after.

### 4.8 `keep_arrival` is retired as a filter

`keep_arrival = !is.na(f_pass_arrived)` was classified as a **population** flag
on the argument that "a throw that arrived somewhere" is part of the question's
scope. §6 rejects that classification and the flag with it: the label is missing
on half of all incompletions, so it is neither a population definition nor
ignorable attrition.

The flag stays in `FLAG_LABELS` and `flag_marginals()` as a diagnostic — its
marginal failure count is the headline number in §6 — but it appears in no rule
and must not enter the `08` funnel. Arrival is now derived, not read.

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

**Denominator caveat.** The labeled week is 13 games, not 16 (§3).

---

## 6. The arrival anchor

Reported in full in `analysis/02_arrival_anchor.qmd`. All counts below are
**week 1 only** ($n = 890$ plays with a tracked target, across 13 games) except
§6.1, which is full-season. Re-validate at season scale once `06` runs; the
checklist is §6.8.

Every coverage feature is anchored to two points: the ball at the throw, and the
ball at arrival. The throw is unambiguous. Arrival required three attempts.

### 6.1 The problem: `pass_arrived` missingness is selection on the response

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
rather than a week-specific collection artifact. No subset of weeks escapes it.

### 6.2 Rejected: the `pass_outcome_*` family as a substitute anchor

Coverage is adequate — an outcome label (`caught`, `incomplete`,
`interception`, `touchdown`, earliest taken) exists on **99.7%** of plays,
including nearly every incompletion the arrival label misses. Position is not.
On plays carrying both labels, ball displacement between them:

| `pass_result` | p50 gap (frames) | p50 (yd) | p90 (yd) | p50 $\Delta x$ (yd) |
|---|---|---|---|---|
| C | 3 | 1.89 | 4.44 | +0.90 |
| I | 5 | 3.51 | 8.11 | +1.76 |
| IN | 5 | 2.30 | 5.95 | +1.06 |

The error is systematically downfield and its magnitude depends on the outcome.
The passing-window corridor is 2–3 yd wide, so a p90 error of 8 yd is
disqualifying. Physical cause: `pass_outcome_incomplete` fires when the ball
hits the turf, well past the receiver.

### 6.3 Rejected: first local minimum of ball-to-receiver distance

$f_{\text{arr}} = \min\{f : d_{f+1} > d_f\}$, on the reasoning that a local
minimum is the end of the flight by construction while a global minimum could
land after a bounce (§3: there is no $z$ coordinate).

Three failure modes: **76 plays** returned flight times under $0.2$ s, because
one frame of jitter after release ends the search; the post-catch carry keeps
$d$ near zero for many frames so the first uptick is decided by noise
(disagreement with the global minimum on **318 of 564** completions); and on
badly thrown passes $d$ never rises, so the rule returned the window edge
(**41 of 295** incompletions). Completion p90 of $d_{\text{arr}}$ was $0.917$ yd
with a maximum of $28.4$ yd — face validity failing on the one class where it
should be trivial.

### 6.4 Rejected: closest approach within a tolerance $\epsilon$

$f_{\text{arr}} = \min\{f : d_f \le \min_g d_g + \epsilon\}$ with
$\epsilon = 0.25$ yd, presented as a tie-break across the near-zero plateau at
the coordinate rounding scale.

Face validity was good (completion p50 $d_{\text{arr}} = 0.300$ yd, max $1.13$
yd). Rejected on two counts anyway:

1. **It failed its own sensitivity check.** Halving $\epsilon$ to $0.10$ changed
   the selected frame on **62%** of plays (agreement $0.382$, median shift 1
   frame in each direction). There is no plateau: $d$ shrinks gradually through
   the catch, so $\epsilon$ was not absorbing rounding, it was *choosing how
   close counts as arrived*. A substantive modeling parameter presented as a
   numerical tolerance.
2. **The criterion is relative, so the standard varied by outcome.** With
   $\min d \approx 0$ on completions and $\approx 1$ yd on incompletions,
   $d \le \min d + \epsilon$ applied a different absolute threshold to each
   class — the exact property the exercise exists to eliminate.

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

The distribution of ball `dis` over the search window is cleanly bimodal —
carry and dead ball below $\approx 1.0$, flight at $\approx 2.1$, valley floor
around $1.0$–$1.2$ yd/frame. The histogram is the justification for §6.6 and
belongs in the report as a figure.

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
no player can exceed (§4.2), so a ball above it cannot be in anyone's hands.
Set as an alias in `R/constants.R` with the argument recorded at both ends, so
a future revision of `MAX_SPEED` cannot silently move the arrival definition.

Three components of the rule, each with its own justification:

- **The $f \le f_{\min}$ bound** makes a post-bounce frame unreachable.
  Measured: only 6 plays of 890 show more than $1$ yd of rise between
  $f_{\text{arr}}$ and $f_{\min}$, p99 rise $0.885$ yd, so the ball moves
  monotonically toward closest approach and the guard is belt-and-braces rather
  than load-bearing.
- **Runs of flight-speed frames separated by fewer than `ARRIVAL_GAP_TOL`
  frames are merged.** The two extremes are both wrong, and they disagree on
  **92 of 890** plays (10.4%), median gap 2 frames, max 37. A tolerance of 0
  lets one frame of jitter on a wobbling ball end the flight early; an unbounded
  tolerance lets a jittery frame during a catch-and-run be selected as the
  flight end. **Value set: `ARRIVAL_GAP_TOL = 2` frames**, from the sensitivity
  table in notebook §7.4, where $d_{\text{arr}}$ is stable across the grid and
  similar between classes. Because the table is flat, the parameter does not
  materially matter and the choice costs nothing to defend.
- **The end of the first merged run, not its start.** The start is the release.

**Validation.**

- *Implied ball speed by 2-yd depth bin* — the decisive check, since a timing
  artifact would show up as outcome-dependent ball speed. Agreement between
  completions and incompletions within $\approx 1$ yd/s in all 11 bins, flat at
  $\approx 21$ yd/s across depth. Under §6.4 the same table split $12.0$ against
  $17.0$ yd/s at short depth, converging only past $26$ yd — the signature of a
  fixed number of contaminated frames rather than a football fact. Lane length
  matches across classes within each bin, so the comparison is not a binning
  artifact.
- *$\delta$ sensitivity* — frame agreement $0.869$ at $\delta = 1.0$ and $0.817$
  at $1.6$, median shift 0 in both directions. Against $0.382$ for $\epsilon$.
- *Face validity* — median $d_{\min}$ on completions $0.121$ yd, confirming the
  underlying distance series is right and only the frame selection changed.
- *Class similarity* — median $d_{\text{arr}}$ of $0.690$ yd (C) and $1.16$ yd
  (I). The residual difference is a football fact, not an artifact: a caught
  ball genuinely ends up closer to the receiver than a dropped one. Similarity
  across classes, not proximity to zero, is the correct target.
- *Relationship to `pass_arrived`* — the label fires at a consistent
  ball-to-receiver distance across classes ($1.09$, $1.18$, $1.98$ yd), so the
  labelers are marking the ball arriving in the receiver's vicinity. What
  differs by outcome is the remaining flight after that yard: median gap of
  $+3$ frames on completions, $0$ on incompletions. On plays where the label
  fires first the gap closes monotonically (85% of completions, 94% of
  incompletions) with median net change negative in every class, so the label is
  **early** rather than marking a different event. The adopted anchor is the
  later and physically correct one.

**Costs, stated for Methods.**

1. **Requires a tracked targeted receiver.** Plays without one are throwaways
   and spikes and are disproportionately incomplete, so `keep_target` is
   outcome-correlated. This is acceptable as a *population definition* — the
   question is about targeted passes — and belongs in the `08` funnel framed
   that way. It is not acceptable to smuggle the same selection in through a
   measurement rule, which is what §6.1 would have done.
2. **The definition is the project's own construction**, not a dataset label.
   Validated against `pass_arrived` on the plays where that exists, and
   externally against nflverse `air_yards` (§6.8).
3. **Arrival timing is influenced by the outcome** to the extent that a caught
   ball's flight ends in the hands. The §6.6 speed check bounds this at
   $\approx 1$ yd/s of implied speed, which is why it is stated as a bound
   rather than dismissed.

**Diagnostics travel with the output and are not filtered on:** `d_arr`,
`d_min`, `f_min`, `frames_to_min`, `used_fallback`, `at_window_edge`. Same
pattern as `has_kinematic_defect` / `defect_in_window` (§4.2).

`frames_to_min` is catch-plus-carry duration, not a gather time — $f_{\min}$ is
the deepest point of the carry, since $d$ stays near zero while the receiver
holds the ball. Median 8 frames on completions, 0 on incompletions.

$\approx 2.8\%$ of plays never reach flight speed inside the window
(`used_fallback`) and fall back to closest approach. These are batted balls and
soft flips with very short lanes; most exit at the beyond-the-LOS filter.

### 6.7 Two things `d_arr` must never be used for

**Not a model feature.** A ball ending up $0.12$ yd from the receiver *is* the
catch. `d_arr` or `d_min` in the feature set would drive log loss down while
saying nothing about whether coverage geometry carries information.

**Not a filter.** A pass that never got near its target is a real play with real
coverage geometry, and it is almost by definition an incompletion. Excluding on
$d_{\text{arr}}$ would reintroduce exactly the selection on outcome that §6.1
rejected. Sensitivity to `used_fallback` and `at_window_edge` is checked at the
model stage instead.

### 6.8 Full-season checks to re-run once `06` exists

Before any feature work. The week-1 numbers above are the benchmark.

1. **Class similarity** of $d_{\text{arr}}$, all 17 weeks.
2. **Speed equalization** by 2-yd depth bin, all 17 weeks. The result the
   definition rests on.
3. **Bounce check**, since a rarer artifact may only appear at 17× the sample.
4. **Three plays rendered with `render_play()`** — one completion, one
   incompletion, one interception — stepped to $f_{\text{arr}}$ to confirm
   visually that the ball is where the number says. A sign error or an
   off-by-one is invisible in a summary table and obvious in an animation.
5. **External validation against `air_yards`.** Compare
   $x_{\text{arr}} - \texttt{los\_x}$ against nflverse `air_yards` (§8). This is
   an independently human-charted measurement of the same quantity from a
   separate source, and it is the strongest outside check available on a
   definition that is otherwise the project's own construction. Also validates
   the sign convention and settles the beyond-the-LOS threshold (§7).

---

## 7. Open items

**Research question: settled.** Completion probability at the throw, predicted
from tracking-derived coverage geometry — receiver separation, leverage, the
passing-window corridor, time-to-arrival, and QB kinematic state — on passes
thrown beyond the line of scrimmage to a tracked targeted receiver. Separation
is a feature of that model rather than a separate question.

Scoped out, with reasons: **coverage classification** (labels exist for week 1
only, §3, and there is recent published work), and **space-control / pitch-
control modeling** (time). Both are future work.

**Modeling strategy: settled.** Binomial GAM via `mgcv` across four nested
stages — intercept only, play-by-play features, plus separation, plus full
geometry — with nflverse `cp` joined as a fifth, external benchmark rather than
fit. The money table is out-of-sample $\Delta$ log loss across those fits.
Leave-one-week-out cross-validation (17 folds). Calibration is the headline
rather than AUC: reliability overall plus calibration within separation and
air-yards buckets.

**Closed since the last revision.**

- The arrival anchor (§6) and `ARRIVAL_GAP_TOL = 2` (§6.6).
- The nflverse join lands: 19,238 of 19,239 plays, zero outcome disagreements
  (§8.2). Key uniqueness asserted in `standardize_pbp_keys()`.
- Whether nflverse `pass_attempt` includes sacks: it does (§8.2).
- **`qb_hit` is a covariate, not a filter.** It is play-level and does not
  distinguish "hit during the throw" from "hit after," so excluding it removes
  real passes and may itself select on outcome. Including it as a feature is
  more informative and cheaper to defend, with a sensitivity check dropping
  those plays. Present on 2,761 plays (14.4%).
- **`qb_spike` (75 plays) and `qb_scramble` (7 plays) are population filters,
  not features.** Neither is an attempted pass. They belong in the `08` funnel.

**Immediate decisions still open.**

- `keep_arrival` is retired as a filter (§4.8); confirm it appears in no rule
  before `08` is written.
- **Beyond-the-LOS threshold.** Now quantified: of the 17,343 plays with
  charted `air_yards`, **20.9% are at or below zero** — 2,529 negative and
  **1,093 at exactly zero**. The zero block is 6.3% of charted plays, too large
  to wave through as ambiguous, so the threshold is set on the continuous
  tracking-derived throw distance from `06` rather than on a charted integer,
  and validated against the `air_yards` sign (§6.8). Provisional cost of the
  filter: roughly a fifth of the sample.
- **`keep_official_play`.** Whether the 633 penalty-nullified plays belong in
  the sample. Provisionally retained; see §8.3 for the argument and the
  sensitivity to run.
- **Corridor width**: 2 yd or 3 yd.
- **Robustness**: refit with `PLAYER_S_MAX` at $9.22$ and $9.98$ and report that
  log loss barely moves.
- Whether the man/zone binary earns a place in the model at all, given §5 and
  the 13-game denominator.

**Phase 0 checks not yet run.**

- Do throwaways already carry `NA` target? If so `keep_target` handles them and
  no pbp-derived flag is needed. Validate against nflverse
  `receiver_player_name`.
- Do QB spikes already carry `NA` target? Now validatable against the 75
  `qb_spike` plays in `pbp.parquet`.

**Play types measurable but not yet filtered.** `SAMPLE_RULE` is
question-agnostic by design: it removes plays that are not live, not pass
attempts, or not measurable. It does **not** remove play types that are
measurable but may be inappropriate for a given question. Currently retained:

- QB spikes (clock management, no intended receiver)
- Throwaways (real throw, no receiver targeted)
- Screens and other passes behind the LOS (separation dynamics differ)
- Penalty-nullified plays (real tracking, no official play)
- Batted or tipped passes at the line (outcome set before separation matters)
- Hail Marys (coverage geometry unrelated to the usual model)
- Goal-line plays with extra linemen
- Two-point conversions, if present

Intended approach: flag these in `sample_flags` **without filtering**, so each
candidate question selects its own population on top of a shared base.
Identification is via the nflverse join (§8), which supplies `qb_spike`,
`qb_scramble`, `qb_hit`, and `play_type`. The population filters for *this*
question are applied in `08_build_model_frame.R` and reported as a second
funnel, separate from the base sample funnel in §4.5.

**Feature state.** `R/geometry.R`, `R/arrival.R`, `R/pbp.R`, and
`scripts/05_join_pbp.R` exist and are tested; `pbp.parquet` is built. No feature
table exists yet. `scripts/06_build_throw_frame.R` is next: apply
`detect_arrival()` at season scale and emit the throw-frame slice (all tracked
players at $f_{\text{throw}}$ and at $f_{\text{arr}}$) that the feature script
consumes. Because `pbp.parquet` exists, model stages 1, 2, and 5 are unblocked
independently of `06` and `07`.

**Deferred to future work.**

- Assigned-defender separation (needs coverage classification)
- Passes behind the LOS — screens have different separation dynamics
- An at-arrival model as $\hat p_{\text{arrival}} - \hat p_{\text{throw}}$, a
  defender "closing space" credit. Two applications of the same model, not a new
  one.
- Position-specific motion parameters
- Ordinal C/I/IN response

---

## 8. The nflverse play-by-play join

`scripts/05_join_pbp.R`, with the bridge in `R/pbp.R`. Outputs
`data/processed/pbp.parquet` (one row per play, on the plays keys) and
`pbp_outcome_agreement.parquet` (the join check, persisted so it can be
re-displayed rather than only asserted at build time).

**Why the join exists.** Four things the Kaggle download does not have: `cp`
(the external benchmark), `air_yards` (BDB's `plays.csv` carries no throw depth
at all), the pressure and spike flags, and game-state context. Everything else
the play-by-play model stage needs was already in `plays.parquet` —
`down`, `yards_to_go`, `quarter`, `offense_formation`, `type_dropback`,
`defenders_in_the_box`, `number_of_pass_rushers`, and BDB's own penalty columns.
The play-by-play model stage is therefore mostly local, and this join supplies
depth, pressure, and the benchmark.

**Counts in this section are on the full 19,239-play spine**, not the analytic
sample, so they are not directly comparable to §4 or §6.1.

### 8.1 Provenance and keys

**Pull.** `nflreadr` 1.5.1, nflverse data release 2025-04-30, 47,109 rows ×
372 columns, mirrored verbatim to `data/interim/pbp_2018.parquet` with a
provenance sidecar (`pbp_2018_meta.parquet`). nflverse revises its data between
releases, so results produced in October have to reproduce in December — the
same argument as the `01` mirror layer. `nflverse_timestamp` is an *attribute*
on the returned object and attributes do not survive a Parquet round trip, so
the sidecar is written inside the download branch or the release identity is
lost permanently. The build condition covers both files, so a mirror without its
sidecar triggers a re-pull rather than being silently accepted.

**Keys.** `gameId` → `old_game_id` (character, cast to `int32`), `playId` →
`play_id` (double, cast to `int32`). A type mismatch on a join key returns zero
matches rather than an error (§1), so the cast is load-bearing.
`standardize_pbp_keys()` errors rather than warns on an unparseable or
duplicated key, because a duplicated pbp key would fan out the plays spine
silently. nflverse's own `game_id` is the `2018_01_ATL_PHI` schedule key and is
dropped rather than carried alongside — two columns named `game_id` meaning
different identifiers is exactly the failure this bridge exists to prevent.

**Game sets, compared in both directions.** 0 BDB games absent from nflverse —
asserted, because a nonzero value would mean the cast produced identifiers that
do not exist and a total join failure would present as a merely low match rate.
14 nflverse games absent from BDB: 11 postseason (weeks 18–21) plus the 3 week-1
games BDB omits. That second finding is recorded as a structural constraint in
§3.

### 8.2 The join is verified on identity, not coverage

**Why a match rate is insufficient.** A high proportion of keys finding a
partner is consistent with having matched real keys to the *wrong* plays. That
failure would put one play's air yards beside another play's coverage geometry,
and the resulting model would train, converge, and report plausible log loss.
So the join is verified using two facts both sources record independently: the
outcome and the description.

| Check | Result |
|---|---|
| Key match rate | 19,238 / 19,239 (99.9948%). The single unmatched play is a Q4 completion. |
| Outcome cross-tab | **0 disagreements** across 18,605 checkable plays carrying a real nflverse pass outcome |
| Week redundancy (`week` vs `week_pbp`) | 0 mismatches — asserted |
| Description token similarity | p10 $0.81$, p50 $0.86$, 90.9% above $0.8$ |

**`pass_attempt` is 1 on sacks**, so no sack falls through to the
no-pass-recorded class and the (S, sack) cell is populated. This was ambiguous
in the documentation and is settled empirically.

**Exact description agreement is 0 by construction, and that is not a defect.**
nflverse prefixes every player with a jersey number (`9-M.Stafford` against
`M.Stafford`) and uses modern team abbreviations where BDB's description strings
use the league's internal ones (`LV`/`OAK`, `ARI`/`ARZ`, `CLE`/`CLV`,
`HOU`/`HST`). A first-40-character prefix comparison agreed on 5 plays of 19,238
for the same reason, and was replaced by Jaccard overlap on whitespace tokens,
which is invariant to insertions, deletions, and reordering. The replacement
measures whether two strings describe the same play rather than whether they
were typeset the same way, which is the question the check is actually asking.

**Three kinds of non-agreement are separated in `outcome_agreement()`**, because
conflating them is easy and only the first indicts the join: a checkable play
whose real pass outcome disagrees; a play with no pbp row; and a matched play
where nflverse logged no pass at all. The last is §8.3.

### 8.3 The penalty-nullified block is selected on outcome

**633 plays** carry `play_type == "no_play"`. Every one carries BDB penalty
codes; **237 are defensive pass interference**. Of these, 627 are a genuine
disagreement between the two feeds about whether a pass occurred; the remaining
6 are 4 scrambles (where "no pass recorded" is the *correct* answer) and 2 plays
with no BDB `pass_result`.

| | n | Complete | Incomplete | Intercepted |
|---|---|---|---|---|
| Not nullified | 17,345 | 65.0% | 32.7% | 2.3% |
| Nullified | 579 | **17.8%** | **79.8%** | 2.4% |

Defensive PI nullifies incompletions, which is the mechanism. The skew is
sharper than the missing-LOS block of §4.7 and points the same direction.

**`cp` is `NA` on all 633.** nflfastR does not compute completion probability
for a play it records as not having happened. So the benchmark's scoring
population is not merely "plays with charted air yards" — it systematically
excludes a block that is 80% incomplete. The base rate on the `has_cp` subset
runs about 1.5 percentage points high: **63.43% on the full matched set against
64.95% on `has_cp`.** Stated, not caveated.

**Decision, provisional.** BDB's `pass_result` records what physically happened
to the football, which *is* the response variable. A flag on the play does not
change whether the ball was caught, and the coverage geometry is real. So
nullified plays are **retained** in the tracking-stage sample; the benchmark
comparison runs on the `has_cp` subset with the base-rate shift reported; and
`keep_official_play` is flagged in `R/sample_rules.R` so the sensitivity can be
run both ways. Open item in §7.

**A constraint on the money table.** $\Delta$ log loss across model stages is
only comparable when every stage is scored on the same rows. The headline
benchmark comparison therefore runs on `has_cp == TRUE`, with full-sample
numbers for stages 1–4 reported alongside.

### 8.4 Availability

| Column | Present | Share of spine |
|---|---|---|
| `pbp_matched` | 19,238 | 99.99% |
| `cp` | 16,853 | 87.6% |
| `air_yards` | 17,343 | 90.1% |

Of the plays carrying `air_yards`: 2,529 negative, 1,093 exactly zero, 20.9% at
or below zero. That figure is the provisional cost of the beyond-the-LOS
population filter and the reason its threshold is still open (§7).

Flags: `qb_hit` 2,761 (14.4%), `qb_spike` 75, `qb_scramble` 7,
`play_type == "no_play"` 633.

`has_cp` and `has_air_yards` travel with the data rather than being filtered on,
the same pattern as `defect_in_window` (§4.2) and the arrival diagnostics (§6.6).
`pbp_matched` is a sentinel set on the pbp table *before* the join rather than
inferred from `is.na()` on a content column afterwards, because `cp` and
`air_yards` are legitimately missing on matched rows and inferring would
conflate "no pbp row" with "pbp row without a charted throw".

### 8.5 Leakage discipline

**Excluded as leaks**, asserted by `assert_no_leak_cols()` against both exact
names and regex families: `cpoe` — which is
$100 \times (\texttt{complete\_pass} - \texttt{cp})$ and therefore contains the
response exactly — every EPA and WPA derivative, `yards_gained`,
`yards_after_catch`, and BDB's own `epa`, `play_result`, and
`offense_play_result`, which `02_build_canonical.R` writes through verbatim.

A leak of this kind is invisible in a log-loss table: the model simply looks
excellent. Hence a named constant with a build-time assertion rather than a
careful `select()` in one script.

Pre-play quantities are deliberately **not** excluded: `ep`, `wp`, `vegas_wp`,
`spread_line`, `total_line` are legitimate context features.

**`pbp.parquet` deliberately retains the outcome columns** (`complete_pass`,
`interception`, `sack`, `pass_attempt`, `play_type`) so §8.2 can be re-run from
the persisted artifact rather than only at build time. That makes `05`'s
assertion incomplete by design: **`08_build_model_frame.R` must run the same
assertion against the model frame**, where those columns have to be absent.

### 8.6 Not modeled

- **`pass_length`** (the short/deep factor). Charted independently of BDB and
  disagrees with it on at least one observed play ("short middle" in BDB,
  "deep middle" in nflverse), and it is `air_yards` binned at 15 yards.
  Retained in the artifact; not fed to a model beside `air_yards` or the
  tracking-derived throw distance.
- **`qb_spike`, `qb_scramble`** — population filters, not features (§7).
- **`cp` caveats, for Methods.** nflfastR's completion probability model was
  trained on seasons including 2018, so its predictions here are partly
  in-sample. It also depends on human-charted air yards unavailable to a
  tracking-only model. It remains the field-standard reference, and the claim it
  supports is "tracking geometry adds information beyond play-by-play," not
  "we beat `cp`."

---

## 9. Known technical constraints

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
- A raw `{=html}` CSS block placed before the first slide heading in a Revealjs
  deck renders as a blank slide. CSS belongs in `theme/capstone.scss` under
  `/*-- scss:rules --*/`, or in the YAML `include-in-header`.
- Arrow will not push down `lag()`, so frame-to-frame differencing runs on a
  collected sample rather than the full dataset.
- Arrow's `quantile()` is a t-digest approximation and is the wrong tool for
  extreme-tail work. Tail quantiles are computed from exact bin counts; extrema
  from a separate scalar aggregate.
- Ball rows are roughly one-fourteenth of the tracking data (1.25M rows), so the
  whole season of them collects into memory comfortably. Player rows do not.
- `median()` and `quantile()` without `na.rm = TRUE` return `NA` from a single
  missing value. Ball `s` and `dis` each have exactly one (§2), which is enough
  to blank a summary table.
- Object attributes do not survive a Parquet round trip. `nflverse_timestamp`
  has to be captured at download time or lost (§8.1).
- **A comparison column should carry a label, not `NA`.** `NA == "x"` is `NA`,
  `filter()` drops `NA` rows, and a sum over an `NA`-indexed subset returns
  `NA` — so an `NA` category silently disappears from a disagreement count
  rather than showing up as zero. `nflverse_outcome_class()` returns
  `"no pass recorded"` for exactly this reason; an earlier version returned `NA`
  and hid the 627-play block of §8.3 behind an empty result.
