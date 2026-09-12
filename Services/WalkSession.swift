import ARKit
import AVFoundation
import SwiftUI

final class WalkSession: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()
    let safetyProfile: SafetyProfile
    let configuration: DetectionConfiguration
    let alerts: AlertService
    @Published private(set) var isRunning = false
    @Published private(set) var isEnabled = false
    @Published private(set) var hasFullLookAhead = false
    @Published private(set) var observedGroundDistance: Float = 0
    private var appIsActive = true
    @Published private(set) var status = "Ready to scan"
    @Published private(set) var result: DetectionResult?
    @Published private(set) var pitchDegrees: Float = 0
    @Published private(set) var samplingMask: [CGPoint] = []
    @Published private(set) var groundHeight: Float?
    @Published private(set) var calibrationProgress: Double = 0
    @Published private(set) var hapticTestMessage = ""
    @Published var voiceEnabled = true { didSet { alerts.voiceEnabled = voiceEnabled; if !voiceEnabled { alerts.stop() } } }
    @Published var hapticsEnabled = true { didSet { alerts.hapticsEnabled = hapticsEnabled; if !hapticsEnabled { alerts.stop() } } }
    var viewport = CGSize(width: 390, height: 844)
    private var floorEstimator = FloorEstimator()
    private var stabilizer = DetectionStabilizer()
    private var smoothedOrientation: simd_quatf?
    private var previousRawOrientation: simd_quatf?
    private var heading: SIMD3<Float>?
    private var filteredVelocity = SIMD3<Float>(repeating: 0)
    private var filteredSpeed: Float = 0
    private var previousPosition: SIMD3<Float>?
    private var lastFrameTime: TimeInterval = 0
    private var lastReceivedFrame = Date.distantPast
    private var testingUntil = Date.distantPast
    private var heartbeat: Timer?
    private var generation = 0

    static var supportsLiDAR: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    init(configuration: DetectionConfiguration = .standard, safetyProfile: SafetyProfile = .general) {
        self.safetyProfile = safetyProfile
        var tuned = configuration
        tuned.earlyDistance = max(tuned.earlyDistance, 2 * safetyProfile.warningDistanceMultiplier * 1.5)
        self.configuration = tuned
        self.alerts = AlertService(configuration: tuned, safetyProfile: safetyProfile)
        super.init()
        voiceEnabled = safetyProfile.voiceEnabled
        alerts.voiceEnabled = safetyProfile.voiceEnabled
        session.delegate = self
        session.delegateQueue = .main
    }

    func start() {
        isEnabled = true
        guard appIsActive, !isRunning else { return }
        generation += 1
        let request = generation
        guard Self.supportsLiDAR else { isEnabled = false; status = "Live detection requires a LiDAR-equipped iPhone or iPad."; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: begin()
        case .notDetermined:
            status = "Waiting for camera permission"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.generation == request, self.isEnabled, self.appIsActive else { return }
                    if granted { self.begin() } else { self.isEnabled = false; self.status = "Camera access denied. Enable it in Settings to scan." }
                }
            }
        default: isEnabled = false; status = "Camera access denied. Enable it in Settings to scan."
        }
    }

    private func begin() {
        guard isEnabled, appIsActive else { return }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        previousPosition = nil
        filteredSpeed = 0
        filteredVelocity = .zero
        smoothedOrientation = nil
        previousRawOrientation = nil
        heading = nil
        lastFrameTime = 0
        lastReceivedFrame = Date()
        recalibrateFloor()
        let arConfiguration = ARWorldTrackingConfiguration()
        arConfiguration.frameSemantics = .sceneDepth
        arConfiguration.worldAlignment = .gravity
        session.run(arConfiguration, options: [.resetTracking, .removeExistingAnchors])
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            if Date().timeIntervalSince(self.lastReceivedFrame) > 1.5 {
                self.invalidateReading("Depth unavailable · stop and check your surroundings")
                self.floorEstimator.reset()
                self.groundHeight = nil
                self.calibrationProgress = 0
            }
            if let assessment = self.result?.assessment,
               Date() >= self.testingUntil || assessment.level == .high {
                // A real urgent hazard can preempt a manually triggered debug pattern.
                if assessment.level == .high { self.testingUntil = .distantPast }
                self.alerts.update(assessment)
            }
        }
    }

    func stop() {
        isEnabled = false
        suspend("Walk paused")
    }

    func setSceneActive(_ active: Bool) {
        appIsActive = active
        if active {
            if isEnabled { start() }
        } else {
            suspend("Detection paused · keep PathGuard visible. Scanning resumes when you return.")
        }
    }

    private func suspend(_ message: String, pauseSession: Bool = true) {
        generation += 1
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        if pauseSession { session.pause() }
        heartbeat?.invalidate()
        heartbeat = nil
        endWarningTest()
        stabilizer.reset()
        floorEstimator.reset()
        groundHeight = nil
        calibrationProgress = 0
        samplingMask = []
        result = nil
        hasFullLookAhead = false
        observedGroundDistance = 0
        status = message
    }

    func recalibrateFloor() {
        floorEstimator.reset()
        groundHeight = nil
        calibrationProgress = 0
        invalidateReading("Stand still on flat ground and tilt the camera \(configuration.calibrationPitchText) downward")
    }

    private func invalidateReading(_ message: String) {
        result = nil
        hasFullLookAhead = false
        observedGroundDistance = 0
        samplingMask = []
        stabilizer.reset()
        status = message
        if Date() >= testingUntil { alerts.stop() }
    }

    func testWarning(_ level: RiskLevel) {
        guard level != .low, appIsActive else { return }
        testingUntil = Date().addingTimeInterval(2)
        hapticTestMessage = alerts.test(level)
    }

    func endWarningTest() {
        testingUntil = .distantPast
        alerts.stop()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRunning else { return }
        guard frame.timestamp - lastFrameTime >= 0.1 else { return }
        lastReceivedFrame = Date()
        guard case .normal = frame.camera.trackingState else {
            previousPosition = nil
            filteredSpeed = 0
            filteredVelocity = .zero
            smoothedOrientation = nil
            previousRawOrientation = nil
            heading = nil
            floorEstimator.reset()
            groundHeight = nil
            calibrationProgress = 0
            invalidateReading("Tracking limited · hold the camera steady")
            return
        }
        let dt = Float(max(0.01, frame.timestamp - lastFrameTime))
        let position = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
        var deviceSpeed: Float = .infinity
        if let previous = previousPosition {
            let velocity = (position - previous) / dt
            deviceSpeed = simd_length(velocity) // Includes raising/lowering the phone during calibration.
            if deviceSpeed < configuration.maximumClosingSpeed + 1 {
                filteredVelocity = filteredVelocity * 0.65 + SIMD3<Float>(velocity.x, 0, velocity.z) * 0.35
                filteredSpeed = simd_length(filteredVelocity)
            } else {
                filteredSpeed = 0
                filteredVelocity = .zero
                recalibrateFloor()
            }
        }
        previousPosition = position
        lastFrameTime = frame.timestamp
        let rawOrientation = simd_quatf(frame.camera.transform)
        let orientationStable = previousRawOrientation.map { abs(simd_dot($0.vector, rawOrientation.vector)) > 0.999 } ?? false
        let angularSpeed = previousRawOrientation.map {
            2 * acos(min(1, abs(simd_dot($0.vector, rawOrientation.vector)))) * 180 / .pi / dt
        } ?? Float.infinity
        let calibrationOrientationStable = angularSpeed <= configuration.calibrationAngularSpeed
        previousRawOrientation = rawOrientation
        let blend = 1 - exp(-dt / configuration.orientationTimeConstant)
        let orientation = smoothedOrientation.map { simd_slerp($0, rawOrientation, blend) } ?? rawOrientation
        smoothedOrientation = orientation
        let forward = orientation.act(SIMD3<Float>(0, 0, -1))
        pitchDegrees = CorridorGeometry.downPitch(forward: forward)
        let rawPitch = CorridorGeometry.downPitch(forward: rawOrientation.act(SIMD3<Float>(0, 0, -1)))
        let geometry = CorridorGeometry(configuration: configuration)
        if let message = geometry.guidance(pitch: rawPitch) ?? geometry.guidance(pitch: pitchDegrees) {
            // Also break a partially completed calibration on angle changes.
            if floorEstimator.floorY == nil { floorEstimator.reset(); calibrationProgress = 0 }
            invalidateReading(message)
            return
        }
        let cameraHeading = simd_normalize(SIMD3<Float>(forward.x, 0, forward.z))
        let targetHeading = filteredSpeed >= configuration.stationarySpeed ? simd_normalize(filteredVelocity) : cameraHeading
        if simd_dot(targetHeading, cameraHeading) < 0.5 {
            if floorEstimator.floorY == nil { floorEstimator.reset(); calibrationProgress = 0 }
            invalidateReading("Point camera in your walking direction")
            return
        }
        let oldHeading = heading
        let newHeading = simd_normalize((heading ?? targetHeading) * (1 - blend) + targetHeading * blend)
        heading = newHeading
        let headingStable = oldHeading.map { simd_dot($0, newHeading) > 0.996 } ?? false
        guard let depth = frame.sceneDepth, let observations = depthObservations(depth, frame: frame) else {
            if floorEstimator.floorY == nil { floorEstimator.reset(); calibrationProgress = 0 }
            invalidateReading("Depth unavailable · check the camera view")
            return
        }
        floorEstimator.update(points: observations.compactMap(\.worldPoint), cameraPosition: position,
            heading: newHeading, speed: max(deviceSpeed, filteredSpeed), pitch: rawPitch,
            orientationStable: calibrationOrientationStable, timestamp: frame.timestamp, configuration: configuration)
        calibrationProgress = floorEstimator.progress
        groundHeight = floorEstimator.phoneHeight(at: position)
        guard let floorY = floorEstimator.floorY, let cameraHeight = groundHeight else {
            if deviceSpeed >= configuration.calibrationSpeed || !calibrationOrientationStable {
                invalidateReading("Stand still and hold the phone steady to find the floor")
            } else if !configuration.canCalibrate(pitch: rawPitch) {
                invalidateReading("Tilt the camera \(configuration.calibrationPitchText) downward to find the floor")
            } else if calibrationProgress > 0 {
                invalidateReading("Measuring floor · keep still")
            } else {
                invalidateReading(floorEstimator.isAmbiguous
                    ? "Multiple floor levels visible · aim at the flat ground beneath you"
                    : "Finding floor · show a broad patch of flat ground")
            }
            return
        }
        guard cameraHeight >= configuration.minimumCameraHeight, cameraHeight <= configuration.maximumCameraHeight else {
            recalibrateFloor()
            return
        }
        let right = simd_cross(newHeading, SIMD3<Float>(0, 1, 0))
        var samples: [CorridorSample] = []
        var mask: [CGPoint] = []
        for observation in observations {
            let localRay = SIMD3<Float>(simd_dot(observation.worldRay, right), observation.worldRay.y, simd_dot(observation.worldRay, newHeading))
            guard geometry.intersects(origin: SIMD3<Float>(0, cameraHeight, 0), direction: localRay, cameraHeight: cameraHeight) else { continue }
            mask.append(observation.screenPoint)
            if let point = observation.worldPoint {
                let delta = point - position
                samples.append(CorridorSample(position: SIMD3<Float>(simd_dot(delta, right), point.y - floorY, simd_dot(delta, newHeading))))
            }
        }
        guard let reading = CorridorDetector.analyze(samples: samples, expected: mask.count,
            speed: filteredSpeed, cameraHeight: cameraHeight, configuration: configuration, safetyProfile: safetyProfile) else {
            invalidateReading("Not enough reliable depth · check the camera view")
            return
        }
        samplingMask = mask
        result = stabilizer.update(reading, timestamp: frame.timestamp, headingStable: headingStable && orientationStable)
        observedGroundDistance = reading.observedGroundDistance
        hasFullLookAhead = reading.hasSufficientLookAhead
        status = hasFullLookAhead ? "Scanning · floor calibrated" :
            "Near-range scanning · raise phone slightly to see farther ahead"
        // Keep real nearby hazard warnings, even when the farther corridor is unseen.
        // The UI must not show a green clear-path state in this limited view.
    }

    private struct DepthObservation {
        let screenPoint: CGPoint
        let worldRay: SIMD3<Float>
        let worldPoint: SIMD3<Float>?
    }

    /// Decode once per frame for both floor fitting and corridor detection. Invalid
    /// returns keep their rays for coverage measurement, but never become 3D points.
    private func depthObservations(_ depth: ARDepthData, frame: ARFrame) -> [DepthObservation]? {
        let buffer = depth.depthMap
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let confidence = depth.confidenceMap
        if let confidence {
            guard CVPixelBufferLockBaseAddress(confidence, .readOnly) == kCVReturnSuccess else { return nil }
        }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let inverseDisplay = frame.displayTransform(for: .portrait, viewportSize: viewport).inverted()
        let intrinsics = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution
        let translation = frame.camera.transform.columns.3
        let cameraPosition = SIMD3<Float>(translation.x, translation.y, translation.z)
        var observations: [DepthObservation] = []
        observations.reserveCapacity(48 * 72)
        for y in 0..<72 {
            for x in 0..<48 {
                let screenPoint = CGPoint(x: (Double(x) + 0.5) / 48, y: (Double(y) + 0.5) / 72)
                let sensorPoint = screenPoint.applying(inverseDisplay)
                guard sensorPoint.x >= 0, sensorPoint.x < 1, sensorPoint.y >= 0, sensorPoint.y < 1 else { continue }
                let worldRay = DepthProjection.worldRay(
                    sensorPixel: SIMD2<Float>(Float(sensorPoint.x * resolution.width), Float(sensorPoint.y * resolution.height)),
                    intrinsics: intrinsics, cameraTransform: frame.camera.transform)
                let px = min(width - 1, Int(sensorPoint.x * Double(width)))
                let py = min(height - 1, Int(sensorPoint.y * Double(height)))
                var reliable = true
                if let confidence, let address = CVPixelBufferGetBaseAddress(confidence) {
                    let cx = min(CVPixelBufferGetWidth(confidence) - 1, Int(sensorPoint.x * Double(CVPixelBufferGetWidth(confidence))))
                    let cy = min(CVPixelBufferGetHeight(confidence) - 1, Int(sensorPoint.y * Double(CVPixelBufferGetHeight(confidence))))
                    reliable = address.advanced(by: cy * CVPixelBufferGetBytesPerRow(confidence) + cx).load(as: UInt8.self) >= 1
                }
                let depth = base.advanced(by: py * stride).assumingMemoryBound(to: Float.self)[px]
                let point: SIMD3<Float>? = reliable && DepthFrame.isValid(depth) ? cameraPosition + worldRay * depth : nil
                observations.append(DepthObservation(screenPoint: screenPoint, worldRay: worldRay, worldPoint: point))
            }
        }
        return observations
    }

    func sessionWasInterrupted(_ session: ARSession) {
        // ARKit already paused capture. Calling pause() here prevents its end callback.
        suspend("Camera interrupted · detection unavailable", pauseSession: false)
    }
    func sessionInterruptionEnded(_ session: ARSession) {
        if isEnabled, appIsActive, !isRunning { begin() }
    }
    func session(_ session: ARSession, didFailWithError error: Error) {
        stop()
        status = "Camera session failed: \(error.localizedDescription)"
    }
    deinit { heartbeat?.invalidate(); session.pause() }
}

struct CameraPreview: UIViewRepresentable {
    let model: WalkSession
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = model.session
        view.automaticallyUpdatesLighting = false
        return view
    }
    func updateUIView(_ uiView: ARSCNView, context: Context) { }
}
