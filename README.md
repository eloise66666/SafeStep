# SafeStep

A single live LiDAR walking assistant for iOS 17+. Start scanning, measure the floor, then receive visual, vibration, and spoken hazard warnings. There are no mode selectors or simulated detection flows.

## Run

1. Open `../SafeStep.xcodeproj` in Xcode 15 or newer. The nested `SafeStep.xcodeproj` is a standalone alternative; open only one.
2. Choose your signing team and run on a LiDAR-equipped iPhone/iPad. Allow camera access.
3. Tap **Start scanning**. Stand still on flat ground with the rear camera tilted slightly down, between 45° and 70°. Here, 0° means the camera points horizontally forward.
4. Show a broad patch of floor and hold steady until calibration completes. The live screen displays **Height above floor** separately from obstacle distance.
5. **Sensor details** contains floor recalibration and Medium/High vibration tests. Vibration must be checked on a physical iPhone; the user’s test devices are iPhone 17 Pro and iPhone 16 Pro Max.

Depth is processed on-device. No server, API key, recording, or network connection is required.

## Floor-distance algorithm

The previous distance-only fallback could treat nearby floor pixels as obstacles before ground calibration. That path and the automatic AR-plane selection are removed. Hazard detection now requires a calibrated floor.

1. Unproject confidence-filtered LiDAR pixels using camera intrinsics and the ARKit camera transform. Coordinates are gravity-aligned; world Y is vertical. Decode once for both calibration and hazard detection.
2. While phone speed is below 0.08 m/s (including vertical movement), rotation is below 10°/s, and camera pitch is 45–70° downward, collect nearby depth points below the phone.
3. Find a horizontal height cluster within 3.5 cm residual tolerance. Require at least 40 points, 40% support, 0.4 m lateral width, 0.5 m forward length, and coverage of at least eight spatial cells. This rejects walls, narrow patches, sparse returns, and isolated noise.
4. Reject competing supported floor levels instead of picking one arbitrarily. Require the estimated floor height to agree for approximately one second. Report **vertical phone height = camera world Y − calibrated floor Y**, not the slanted range along a camera ray.
5. Keep floor Y fixed while walking. Raising or lowering the phone changes its measured height; approaching a lower landing does not redefine the floor. Floor-level points are excluded from obstacles; objects over 18 cm above the floor remain candidates. Drop detection requires observed lower ground and supporting near ground.

Until calibration succeeds, the app shows floor guidance and produces no automatic hazard alerts. Missing/limited tracking clears readings; tracking loss and session restarts require fresh calibration. Duplicate frame timestamps do not keep stale results alive. Use **Measure floor again** after moving to a different floor level. Extreme viewing angles produce positioning guidance. A limited far view does **not** discard nearby obstacles: it reports near-range scanning and still alerts for visible hazards. A green clear-path state requires sufficient observed floor reach; a near-only view displays **Limited view**. Calibration tilt and usable detection reach are different things: at 45–70° downward, the camera often cannot see 3 m ahead.

## Background behavior

**Obstacle detection cannot run behind other iPhone apps with the current ARKit architecture.** ARKit stops processing frames when camera/motion capture is interrupted, including when an app enters the background. Background audio or a repeating background task does not grant continued ARKit/LiDAR frames. AVFoundation camera multitasking/PiP capabilities are separate APIs, not an ARSession setting.

The app now remembers an enabled walk across temporary inactivity, explicitly clears detection while inactive, and resumes with fresh floor calibration when it returns to the foreground. Manual Pause stays paused. Camera interruptions invalidate readings without calling `ARSession.pause()` inside the interruption callback; when the interruption ends, an enabled foreground session restarts. Scanning keeps the screen awake while visible. There is no background-mode entitlement or simulated background detection.

References: [Apple ARKit session interruptions](https://developer.apple.com/documentation/arkit/arsessionobserver/sessionwasinterrupted(_:)), [AVFoundation camera multitasking on iPad](https://developer.apple.com/documentation/avkit/accessing-the-camera-while-multitasking-on-ipad), [PiP for video calls](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-for-video-calls).

## Warnings

For walking with sufficient view: above 3 m is clear, 2–3 m is early caution, 1.2–2 m is warning, and below 1.2 m is immediate danger. Fast motion extends distances; stationary motion reduces advance warnings. Reliable closing-distance trends with stable support position can escalate via TTC; changing supporting surfaces, turns, inconsistent rates, and data gaps reset that estimate. Immediate escalation and delayed release with hysteresis reduce warning chatter.

Medium gives two full-intensity sustained pulses. High gives three urgent sustained pulses plus speech when Voice is enabled. Voice/Touch controls, cooldowns, cached haptic players, pause/resume, and hardware tests are retained. Test buttons explicitly play audio/haptics regardless of the switches and defer live feedback for two seconds.

Tuning values are centralized in `Models/RiskAssessment.swift` → `DetectionConfiguration`. The old additive debug score and mode-specific branches are removed; warning stages drive the UI and alerts directly.

## Validation

Run the platform-independent checks with a compatible Swift SDK:

```sh
swiftc Detection/DepthProcessing.swift Models/RiskAssessment.swift Tests/DetectionTests.swift -o /tmp/safestep-tests
/tmp/safestep-tests
```

If the default SDK is newer than the compiler, pass `-sdk /path/to/compatible/MacOSX.sdk`. Tests cover calibration timing, motion/angle rejection, wall and sparse-point rejection, floor noise, phone-height changes, fixed floor references, actual obstacles/drops, TTC, hysteresis, and the original grid utilities.

The current suite passes **127 checks**, including portrait sensor-ray projection at 45°, 55°, 65°, and 70°, competing floor levels, near-view detection, very close obstacles, and small close objects against a large distant wall. Swift syntax and project-file validation also pass. Full iOS compilation, physical haptic strength, and live floor measurement remain unverified in this workspace. On each test iPhone, compare the displayed height with a measured phone-to-floor height while stationary, then check a flat walk at several downward angles. Verify a real obstacle still warns after calibration. Test a nearby object while the distant floor is out of view: it should warn rather than discard the reading. Check **Limited view** on a near-only flat-floor view. Switch to another app and return: detection must be unavailable while away and resume calibration on return. Manually pause before switching apps and confirm it remains paused.

This is a prototype: horizontal-plane geometry cannot semantically distinguish every broad tabletop or landing from a floor. Calibrate while showing actual flat ground. Slopes, tracking drift, glass, reflective surfaces, and thin objects can still cause incorrect or missed detections. The 18 cm obstacle-height cutoff can miss lower trip hazards. Thresholds are tunable, not certified safety values.

## Source map

- `Detection/DepthProcessing.swift`: original depth/grid utilities, floor estimation, corridor geometry and detector.
- `Models/RiskAssessment.swift`: configuration, warning stages, movement and temporal filtering.
- `Services/WalkSession.swift`: ARKit lifecycle, depth decoding, calibration and live detection.
- `Services/AlertService.swift`: haptics and speech.
- `StartView.swift`, `LiveDetectionView.swift`, `DebugPanel.swift`: start, live view and sensor details.
