---
name: biomech-rules
description: Design of the LiftIQ biomechanics rules engine — calibration baselines, rep detection state machine, phase tagging, form flags (lumbar flexion, hip hinge, knee valgus), form score policy, and how to validate rules. Use when adding/changing analysis rules, thresholds, rep detection, or when asked about squat/deadlift form logic.
---

# Biomechanics Rules Engine

## Core principle (non-negotiable)

**All rules are relative to a per-person calibration baseline, never absolute angles.** A tall lifter with long femurs shows 45° trunk lean on a perfect squat; a short lifter shows 25°. Fixed thresholds misfire on both. VidCalc.py locks a baseline from the first `CALIBRATION_FRAMES = 40` standing frames (mean lumbar + trunk lean), and flags fire on *deviation from baseline*.

Corollary: every session must start with the lifter standing still in view. If calibration never locks, the session's flags are meaningless — VidCalc prints a warning; frontends must surface `"calibrated": false` prominently.

## Rep detection (current: squat-specific)

Knee-angle state machine with hysteresis (VidCalc.py CONFIG block):
- entry: knee < `SQUAT_ENTRY_ANGLE` (120°) → in rep
- exit: knee > `SQUAT_EXIT_ANGLE` (125°) after ≥ `MIN_REP_FRAMES` (8) processed frames
- The 5° gap + minimum frames kill jitter-double-counting. Don't "simplify" them away.

**iOS addition (2026-07-21, RulesEngine.swift, not yet in VidCalc):** the 5° gap is NOT enough when a grindy ascent stalls through the 120–125° band — small noise crosses both thresholds twice and double-counts one rep (Conor's real clip: 9 reps read as 17; reproduced synthetically 9→18). Fix: a **re-arm guard** — after a rep counts, the counter is disarmed until the knee exceeds `repRearmAngle` (135°), i.e. the lifter stands back up. Threshold chosen from Squat1 (touch-and-go between-rep peaks 141/151/155°, all ≥135) vs a grind wobble (~128°, <135). Smoothing (One Euro on positions, ported 2026-07-21 in Smoothing.swift) is necessary but was NOT sufficient alone. Both still need validation against Conor's actual failing clip; 135° is provisional. Consider backporting the guard to VidCalc.

**iOS addition (2026-07-21): failed-rep detection.** A failed rep (lifter stalls mid-ascent and dumps the bar) still "completes" mechanically when the lifter stands up afterwards, so it was counted as a clean rep (Conor's real 6-rep clip, last rep dumped: app said 6 good reps). Validated against that real clip (`OutPuts/session_Squat3.json`, per-frame knee trace) — the ground truth is exactly {rep 6} failed.

Two dead ends worth remembering (both false-flagged good reps on the real trace):
1. "rose ≥15° then dropped ≥10° from peak" — flagged 4/6. Grinding ascents dip 8–15° at the sticking point and still complete; a drop from peak is not failure.
2. Post-pass "find global min, look for collapse after it" — **missed** the real failure, because after a genuine dump the pose explodes to garbage-low angles (rep 6 hit 15° then 2°), and those garbage values became the "global min", so there was no ascent left to scan after them.

**The rule that works (online, reset-on-new-minimum):** track the deepest knee so far in the rep (`repMinKnee`) and the highest angle since that deepest point (`repPeakSinceMin`). Fire when `repPeakSinceMin − repMinKnee ≥ failedRepRise` (25°, a real stand-up attempt) **and** `repPeakSinceMin − knee ≥ failedRepCollapse` (30°, it drops back) before lockout. Crucially the peak **resets every time a new, deeper minimum is set** — this is what makes a descent HITCH (real descents wiggle, e.g. 119 → dip 51 → bounce 72 → true bottom 40) never look like an ascent collapse, because each new low resets the peak so the rise stays small. The dumped rep (bottom 45 → attempt 102 → collapse to 15/2) shows a 57° rise then 87° collapse — unmistakable. Checking online catches the collapse at the instant it happens, before the garbage-low readings that fooled the post-pass. Thresholds have margin: worst good-rep collapse-from-peak on the real clip was 25°, so 30° clears it. Rep stays in the list, marked `failed`, shown ✗ in UI, excluded from the (provisional) form score. Tests: real Squat3 → {6}; synthetics clean×3 / dump / bounce / 12° grinder dip / dump-to-garbage / descent-hitch all pass. Still one real clip — widen validation as more labelled failures arrive. Not yet in VidCalc.py; backport with the re-arm guard.

**iOS update (2026-07-23): the online rule alone false-flagged on real Vision 3D.** All the above was validated only on MediaPipe (`session_Squat3.json`). On the actual iPhone (Vision `VNDetectHumanBodyPose3DRequest`, no LiDAR) the *same* Squat3 clip false-flagged reps 2/4/5/6. Vision 3D is far noisier than MediaPipe and — critically — has the **opposite** signature: its knee trace is riddled with **single-frame spikes** (e.g. a 127° blip mid-descent, transient dips to 90–115° while standing), while its *genuine* dump is a **broad multi-frame** collapse. MediaPipe is the reverse: clean, but its real dump is a **sharp 1–2 frame** crash (102→15→2.6). Three fixes made it robust on BOTH (each validated offline on the real device trace AND the MediaPipe fixture → both yield exactly {rep 6}):
1. **Spike rejection** — median filter (`RulesConfig.kneeSpikeWindow`) on the knee signal before detection. A 1-frame Vision spike otherwise trips the 125° exit *mid-descent* and splits one real rep in two (losing the deep part), and fabricates rise/collapse pairs. **Window must be a per-source parameter, not a constant:** Vision uses **3** (kills 1-frame transients, preserves the sustained dump); clean sources (MediaPipe) use **1** (any filtering erases their sharp dump). This is a real property of the pose source's SNR. Median distinguishes failure from noise by duration: a real failure is *sustained*, noise is *transient*.
2. **Depth gate** (`validRepDepth` 100°) — a rep only counts once its knee actually reached squat depth. Kills phantom "reps" from between-rep noise dips (the old false rep 2 bottomed at only ~112°). Real squats here bottom <62°. Phantom frames are retro-marked STANDING so they don't pollute the next rep's bucket.
3. **Non-completing dump** — THE actual root cause. A true dump never returns to standing (lifter stays down / clip ends low), so `knee > exit` never fires and the completion path **detected the collapse then silently discarded it** (in the device log it was the never-closed "rep 7"). Fix: at end-of-pass, if still `inRep` with `repFailed && reachedDepth`, close and flag that rep. Meanwhile the noise-created phantoms *did* complete, which is why the old code flagged the wrong reps. Runtime only ever sees Vision/2D (JSON import was dropped, commit 560991c), so default `kneeSpikeWindow=3`; the fixture test passes 1. Charts now plot the de-spiked knee (depth is more stable).

Phase tagging inside a rep: knee-angle trend over a 7-sample deque — trend < −3 DESCENDING, > +3 ASCENDING, else BOTTOM.

**Deadlift needs a different trigger** — conventional pulls may never break 120° knee. Use hip angle (shoulder-hip-knee) or wrist-landmark height relative to knee. Keep both machines behind one interface: `detect_rep(exercise, frame_metrics) -> phase, rep_event`.

## Implemented flags

**Lumbar flexion under load** — fires when phase == ASCENDING and lumbar lean > baseline + `LUMBAR_FLEX_THRESHOLD` (12°). Rationale: spinal flexion under load during the concentric is the classic injury-risk pattern; during descent some flexion is normal setup variance. Uses SPINE_IDS positions [0] hip → [3] spine_03 (lumbar) and [0] → [5] spine_05 (trunk, excludes neck).

## Flags to implement

- **Hip hinge vs lumbar hinge**: during DESCENDING, hip angle change should dominate lumbar lean change. Ratio `Δlumbar / Δhip` above ~0.5 sustained = hinging through the spine, not the hips. Baseline-normalise both deltas.
- **Knee valgus**: knee tracking inward. **Cannot be measured from sagittal 2D** — parked until the 3D pipeline (depth-3d-spine skill) or a frontal-view mode exists. Do not fake it from side view.
- **Depth consistency**: per-rep min knee angle variance across a set — fatigue indicator, cheap to compute from existing rep_stats.
- **Bar path deviation**: once bar tracking exists (wrist landmark or plate Hough circle) — horizontal drift from vertical line through mid-foot.

## Signal quality rules

- Confidence threshold 0.3 on keypoints; below it, VidCalc carries the last known value. That's acceptable for 1–2 frames; longer gaps should mark the rep `"reliable": false` rather than silently flagging on stale data. (Not yet implemented — see roadmap.)
- Smoothing (implemented 2026-07-06): One Euro filters on positions *before* angle computation — `PointSmoother` in VidCalc.py, params in CONFIG. Raw jitter was ±2–3°, a quarter of the 12° flag threshold. Filter positions, then compute angles — never the reverse. Filters reset after 0.5 s data gaps so a returning keypoint doesn't drag stale history.
- A flag needs ≥ 2–3 consecutive flagged frames before being surfaced to the user (single-frame flags are noise). Frontends currently show raw counts — the rules engine should own the debounce.

## Form score policy

The 0–100 form score in the frontends is **explicitly provisional** — a placeholder heuristic, never validated. Until a validation study exists: keep it out of any research write-up, or replace with the honest alternative (surface raw flags + per-rep table only). Do not tune it to "look right"; that's validation theatre.

## Validating any new rule (the internship deliverable is credibility)

1. **Face validity**: does the flag fire on video where a coach agrees the fault occurred? Collect a small labelled set (even 10 clips, self-labelled with supervisor review).
2. **Test–retest**: same lifter, same day, two sets — flag counts should be stable.
3. **Gold standard**: OpenCap (opencap.stanford.edu — free, research-grade, two phones) is the practical comparator; a Vicon lab if TUS has one. Compare joint-angle time series (RMSE, not just peaks).
4. **Ethics first**: recording identifiable participants = personal data (GDPR). TUS ethics approval before collecting anyone but yourself.

Report sensitivity to: camera angle (±15° off sagittal), distance (2–4 m), clothing (baggy vs fitted), lighting. These are the confounds a reviewer will ask about.
