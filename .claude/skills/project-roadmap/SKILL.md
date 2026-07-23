---
name: project-roadmap
description: Master roadmap and state of the LiftIQ biomechanical squat/deadlift analyser (TUS Athlone internship). Read this first when resuming work on this project, planning next steps, or asked "where were we" / "what's left". Indexes the other project skills.
---

# LiftIQ Project Roadmap

Real-time biomechanical squat/deadlift analyser. Python prototype (developed on Windows/PyCharm) → iOS app. TUS Athlone funded research internship. User: Conor, Python-competent student. **Mac access arrived 2026-07-13** — iOS work is unblocked.

Repo: https://github.com/conormc050/TUS-RISE (layout is authoritative — do not reorganise it). The analysis pipeline lives at `python/VidCalc.py`; wherever these skills say `VidCalc.py`, that's the file. Sample session JSON for frontend testing: `OutPuts/session_Squat3.json`. Note: the mp4s in the repo are committed as plain git blobs despite `.gitattributes` marking them for LFS — they show as perpetually "modified" in `git status`; never stage them, it's a known pre-existing quirk.

## Architecture (current)

```
gym video (mp4)
   └─> python/VidCalc.py
         ├─ MediaPipe BlazePose ─ body keypoints → knee/hip angles
         ├─ SpinePose (dfki-av, ONNX, 37 kpts) ─ estimator.SPINE_IDS → 9 spinal keypoints
         ├─ rep state machine (knee-angle hysteresis 120°/125°)
         ├─ calibration (first 40 standing frames → lumbar/trunk baseline)
         ├─ rules engine (lumbar flexion under load, baseline-relative)
         └─ outputs: annotated mp4, angle_chart.png, rep_summary.png,
                     session_<video>.json (schema_version 1)
                          └─> frontend-web/ (LiftIQ HTML/CSS/JS, iPhone frame mock)
                          └─> frontend-ios/LiftIQ/ (SwiftUI mirror, written blind pre-Mac — needs first Xcode build)
```

## Done

- Full 2D pipeline in `VidCalc.py` (see [biomech-rules](../biomech-rules/SKILL.md) for the logic)
- Rep detection, phase tagging (STANDING/DESCENDING/BOTTOM/ASCENDING), per-rep stats
- Per-person calibration baseline + lumbar-flexion flag
- Session JSON export (see [session-schema](../session-schema/SKILL.md))
- LiftIQ frontends (web prototype + SwiftUI skeleton)

## Next major milestone: 3D spine

Lift the 2D spine keypoints into 3D using depth. Three paths, in order of when they're usable — full detail and code templates in [depth-3d-spine](../depth-3d-spine/SKILL.md):

1. **Now, on Windows**: MediaPipe `pose_world_landmarks` (already computed, ignored today — 3D in meters for free) + monocular depth (Depth Anything V2) sampled at SpinePose pixel positions.
2. **On iPhone with LiDAR**: ARKit `sceneDepth` (256×192 depth map) + camera intrinsics unprojection — the accurate endgame.
3. **Scale anchor fallback** (non-LiDAR iPhones): known body-segment length converts relative depth to metric.

## Remaining work checklist (things easy to forget)

### Engineering hygiene
- [x] `requirements.txt` — pinned from the working venv (2026-07-06)
- [x] `.gitignore` + initial commit (2026-07-06)
- [ ] Golden regression test: run VidCalc on a short reference clip, assert rep count + flag count match known-good values

### Pipeline robustness
- [x] **Smoothing** (2026-07-06): One Euro filters on all landmark/spine POSITIONS (never on derived angles) via `PointSmoother` in VidCalc.py; params in CONFIG (`SMOOTH_MINCUTOFF=1.0`, `SMOOTH_BETA=0.3`), filter state resets after 0.5 s gaps
- [x] **World-landmark 3D baseline** (2026-07-06): `pose_world_landmarks` → `knee_angle_3d`/`hip_angle_3d` per frame, `depth_3d` per rep, teal dotted line on angle_chart.png — this is depth-path validation step 1 (compare vs 2D on sagittal footage)
- [ ] **iPhone video rotation**: iPhone mp4s carry a rotation flag; OpenCV versions differ on honouring it (`cv2.CAP_PROP_ORIENTATION_AUTO`). Videos may arrive sideways — detect and correct, or every angle is garbage
- [ ] **Side auto-detection**: landmarks 11/23/25/27 (left side) are hardcoded; pick side by comparing mean visibility of left vs right landmarks
- [ ] **Person selection**: `keypoints[0]` assumes the lifter is detection #0 — in a real gym pick largest bounding box / most central person
- [ ] **Occlusion handling**: plates occlude hip/knee from sagittal view; currently papered over with last-known-value — add confidence-based interpolation and flag low-confidence reps as unreliable

### Analysis features
- [ ] **Deadlift support**: the rep state machine is squat-specific (knee < 120°); conventional deadlifts have far less knee flexion — trigger on hip angle or bar/wrist height instead. `exercise` field already exists in the JSON
- [ ] **Knee valgus flag**: impossible from sagittal 2D; needs frontal view or the 3D pipeline — park until 3D lands
- [ ] **Hip-hinge vs lumbar-hinge discrimination**: compare hip-angle change vs lumbar-lean change during descent
- [ ] **Bar path tracking**: track wrist landmark or plate centre (Hough circle) — classic lifter-facing feature, cheap to add
- [ ] **Camera-angle guard**: 2D sagittal angles are only valid filmed side-on; detect off-axis filming (shoulder-width-to-hip-width pixel ratio) and warn

### Research/validation (this is an internship — the write-up matters)
- [ ] **Validation study**: compare against a gold standard — OpenCap (free, research-grade, multi-phone) or the university's motion-capture lab if TUS has Vicon
- [ ] **Ethics + GDPR**: recording identifiable people lifting = personal data; TUS ethics approval likely required before collecting participant videos
- [ ] **Replace the provisional form score** — the 0–100 heuristic in the frontend was explicitly marked placeholder; either validate it or present raw flags only
- [ ] **Document coordinate conventions and units** in one place (see session-schema skill) — 3D will multiply the confusion otherwise

### iOS (started 2026-07-13)
See [ios-port](../ios-port/SKILL.md): framework choice matrix, SpinePose-on-iOS options (ONNX Runtime vs CoreML), capture pipeline.

The Xcode project lives at `ios/TUS-RISE/` and is named **TUS-RISE** (Conor's explicit choice — do not rename to LiftIQ; UI branding is TUS-RISE, AppStorage keys are `tusrise.*`).

- [x] Xcode project created; 9 SwiftUI files ported from `frontend-ios/LiftIQ/`, rebranded TUS-RISE, builds and runs in simulator (2026-07-13; only fix: `import Combine` in Models.swift)
- [x] ~~Session JSON import~~ **Dropped 2026-07-16** (Conor's decision): JSON import removed from the app UI — not a shipping feature. The session JSON remains the Python-side export contract and can still be used for unit-test fixtures; validation vs Python now happens by comparing the app's charts/rep tables against VidCalc's outputs directly.
- [ ] Vision 3D pose on imported mp4 → knee/hip angles; validate vs VidCalc.py on the same clip (trends + rep counts must match; raw angles ±3°). **Found 2026-07-14:** `VNDetectHumanBodyPose3DRequest` throws in the simulator (device/macOS only) — `VideoPoseAnalyzer` auto-falls back to 2D `VNDetectHumanBodyPoseRequest` (pixel-space angles, closest match to VidCalc's 2D math). Videos are picked from Photos (drag onto simulator → Photos), not Files. Testing the 3D path needs the app on Conor's iPhone 15 (free Apple ID + Developer Mode).
- [x] Port rules engine + rep state machine (2026-07-14): `RulesEngine.swift` mirrors VidCalc's CONFIG/state machine/compute_rep_stats; verified on Squat1.mp4 (3 reps, sane depths/durations). Deviations documented in the file header: lumbar baseline + lumbar flag dormant until SpinePose; trunk baseline locks independently; no One Euro smoothing yet. Note: Squat1.mp4 has only ~2 s of standing intro — calibration (40 processed frames ≈ 2.7 s) does NOT lock on it, same as Python would; test clips need a longer standing start.
- [ ] Validate Swift angles/reps vs VidCalc.py on the same clip (needs a VidCalc run on Conor's Windows machine → compare angle_chart.png + rep table)
- [ ] Portrait decode fix (2026-07-14): AVAssetReaderVideoCompositionOutput bakes preferredTransform in — verified with a fabricated portrait file. Needs re-confirmation on-device with a phone-recorded portrait video.
- [~] SpinePose via ONNX Runtime (started 2026-07-16): `SpinePoseEstimator.swift` ports the Python package's exact pre/post-processing (bbox+1.25 pad, aspect-fixed 192×256 crop, BGR + mean/std normalize, SimCC decode ÷2; spineIDs [19,26,27,28,29,30,18,35,36]); model `spinepose-s_32xb256-10e_simspine-256x192.onnx` (23.9 MB) is in the app folder. Code is `#if canImport`-guarded — **waiting on Conor to add the SPM package `https://github.com/microsoft/onnxruntime-swift-package-manager` via Xcode UI** (pbxproj must not be edited while Xcode is open). Once added: spine chain feeds lumbar/trunk lean into RulesEngine → lumbar baseline, lumbar flag, true `calibrated`. Then verify against Python on a test clip; depth lifting after.
- [ ] Live camera mode

### Performance
See [performance-optimization](../performance-optimization/SKILL.md) before optimizing anything: profiling method, ROI cropping (biggest untapped Python win), iOS ANE/thermal/battery, LiDAR-path costs, and acceptance targets.

## Design principles (do not violate)

1. Rules are normalised to per-person calibration baselines, never absolute angles — body types vary.
2. Session JSON is a versioned contract; bump `schema_version` on breaking change, keep frontend readers backward-compatible.
3. Prototype on Windows first, keep iOS-specific code isolated so the analysis core stays portable.
4. Never present unvalidated metrics as medical/coaching truth — this is a research prototype.
