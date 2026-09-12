import Foundation
import simd

@main
struct DetectionTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        let vision = SafetyProfile.preset(.vision)
        let mobility = SafetyProfile.preset(.mobility)
        check(!vision.visualAlertsEnabled && vision.voiceEnabled && !vision.voiceOnCriticalOnly && vision.haptics == .strong, "Vision uses strong touch and voice")
        check(mobility.priority(for: .stairs) > mobility.priority(for: .obstacle), "Mobility prioritizes steps")
        var custom = SafetyProfile.preset(.custom)
        custom.warningDistanceMultiplier = 5
        check(custom.warningDistanceMultiplier == 2, "Multiplier upper clamp")
        custom.warningDistanceMultiplier = 0
        check(custom.warningDistanceMultiplier == 0.5, "Multiplier lower clamp")
        custom.setPriority(99, for: .obstacle)
        check(custom.priority(for: .obstacle) == 5, "Priority clamp")
        custom.repeatFrequency = 0
        check(custom.repeatFrequency == 1, "Repeat interval clamp")
        for hazard in [Hazard.obstacle, .stairs, .dropOff, .tooClose] {
            let assessment = RiskEngine.assess(hazard: hazard, distance: 1, movementState: .walking, safetyProfile: vision)
            check(assessment.personalizedDistanceThreshold == hazard.baseDistance * 1.5, "Personalized threshold for \(hazard)")
            check((0...100).contains(assessment.totalRiskScore), "Bounded score")
        }
        func choose(_ hazards: [HazardObservation], profile: SafetyProfile = .general) -> RiskAssessment {
            RiskEngine.assess(hazards: hazards, movementState: .walking, safetyProfile: profile)
        }
        check(choose([.init(hazard: .dropOff, distance: 0.2), .init(hazard: .tooClose, distance: 0.7)]).targetHazard == .tooClose, "Too close beats even nearer drop")
        check(choose([.init(hazard: .obstacle, distance: 1.4), .init(hazard: .stairs, distance: 1.9)], profile: mobility).hazard == .stairs, "Profile priority breaks danger tie")
        check(choose([.init(hazard: .obstacle, distance: 0.5), .init(hazard: .stairs, distance: 2.5)], profile: mobility).hazard == .obstacle, "Danger precedes profile preference")
        check(choose([.init(hazard: .stairs, distance: 1.8), .init(hazard: .dropOff, distance: 1.5)]).hazard == .dropOff, "Distance breaks priority tie")
        check(choose([.init(hazard: .obstacle, distance: .nan)]).level == .low, "Invalid observations excluded")
        check(choose([]).totalRiskScore == 0, "Empty observations clear")
        check(RiskEngine.assess(hazard: .obstacle, distance: 3, movementState: .walking, safetyProfile: vision).stage == .early, "Vision warns earlier")
        func risk(_ distance: Float, movement: Movement = .walking, closing: Float? = nil) -> RiskAssessment {
            RiskAssessment(hazard: .obstacle, distance: distance, movement: movement, closingSpeed: closing)
        }
        for (distance, expected): (Float, WarningStage) in [(2.26, .clear), (2.25, .early), (2.1, .early), (1.5, .early), (1.49, .warning), (0.91, .warning), (0.89, .immediate)] {
            check(risk(distance).stage == expected, "Stage boundary \(distance)")
        }
        check(risk(2.9, movement: .stationary).stage == .clear, "Stationary advance threshold")
        check(risk(2.8, movement: .fast).stage == .early, "Fast movement extends caution")
        check(risk(0.85, movement: .stationary).stage == .immediate, "Immediate stationary protection")
        check(risk(3.5, closing: 2).stage == .warning, "TTC escalation")
        check(risk(2.5, closing: 3).stage == .immediate, "Urgent TTC")
        check(risk(3.5, closing: 0.1).timeToCollision == nil, "Near-zero closing speed rejected")
        check(Movement(speed: 0.14) == .stationary, "Stationary movement")
        check(Movement(speed: 0.15) == .walking, "Walking movement")
        check(Movement(speed: 1.6) == .fast, "Fast movement")
        var tuned = DetectionConfiguration.standard
        tuned.fastOffset = 1
        check(RiskAssessment(hazard: .obstacle, distance: 3.2, movement: .fast, configuration: tuned).stage == .early, "Configurable threshold")

        func result(_ distance: Float, hazard: Hazard = .obstacle) -> DetectionResult {
            DetectionResult(assessment: RiskAssessment(hazard: hazard, distance: distance, movement: .walking), coverage: 1, nearbyFraction: 1, supportPosition: SIMD3<Float>(0, 0.5, distance))
        }
        var filter = DetectionStabilizer()
        _ = filter.update(result(4), timestamp: 0)
        var filtered = result(4)
        for index in 1...4 { filtered = filter.update(result(4 - Float(index) * 0.2), timestamp: Double(index) * 0.1) }
        check(abs((filtered.assessment.closingSpeed ?? 0) - 2) < 0.001, "Stable closing speed")
        check(filtered.assessment.stage == .warning, "TTC causes early escalation")
        check(filter.update(result(0.8), timestamp: 0.5).assessment.stage == .immediate, "No smoothing delay on approach")
        check(filter.update(result(2.5), timestamp: 0.6, headingStable: false).assessment.closingSpeed == nil, "Turns reject TTC")
        filter.reset()
        _ = filter.update(result(1.45), timestamp: 0)
        for index in 1...8 {
            let distance: Float = index.isMultiple(of: 2) ? 1.47 : 1.53
            check(filter.update(result(distance), timestamp: Double(index) * 0.1).assessment.stage == .warning, "Boundary jitter holds warning")
        }
        for index in 9...30 { filtered = filter.update(result(2.1), timestamp: Double(index) * 0.1) }
        check(filtered.assessment.stage == .early, "Stable retreat releases warning")
        filter.reset()
        check(filter.update(result(5, hazard: .clear), timestamp: 4).assessment.stage == .clear, "Filter reset")
        _ = filter.update(result(1), timestamp: 4.1)
        check(filter.update(result(5, hazard: .clear), timestamp: 5).assessment.stage == .clear, "Data gap discards hold")
        filter.reset()
        _ = filter.update(result(3), timestamp: 0)
        for index in 1...5 { filtered = filter.update(result(index.isMultiple(of: 2) ? 3 : 2.8), timestamp: Double(index) * 0.1) }
        check(filtered.assessment.closingSpeed == nil, "Noisy derivatives reject TTC")

        let heading = SIMD3<Float>(0, 0, 1)
        let camera = SIMD3<Float>(0, 1.2, 0)
        var floor: [SIMD3<Float>] = []
        for x in 0..<12 {
            for z in 0..<14 {
                let px = Float(x) * 0.08 - 0.44
                let py = Float((x + z) % 5 - 2) * 0.005
                let pz = 0.55 + Float(z) * 0.09
                floor.append(SIMD3<Float>(px, py, pz))
            }
        }
        func calibrate(_ points: [SIMD3<Float>], pitch: Float = 60, speed: Float = 0,
                       orientationStable: Bool = true) -> FloorEstimator {
            var estimator = FloorEstimator()
            for index in 0...12 {
                estimator.update(points: points, cameraPosition: camera, heading: heading,
                    speed: speed, pitch: pitch, orientationStable: orientationStable, timestamp: Double(index) * 0.1)
            }
            return estimator
        }
        for pitch: Float in [45, 50, 60, 65, 70] {
            let estimator = calibrate(floor, pitch: pitch)
            check(estimator.floorY != nil, "Flat floor calibrates at \(pitch) degrees")
            check(abs((estimator.phoneHeight(at: camera) ?? 0) - 1.2) < 0.02, "Vertical phone height independent of pitch")
        }
        check(calibrate(floor, pitch: 44.9).floorY == nil, "Do not calibrate below 45 degrees")
        check(calibrate(floor, pitch: 70.1).floorY == nil, "Do not calibrate above 70 degrees")
        check(calibrate(floor, pitch: -1).floorY == nil, "Do not calibrate facing upward")
        check(calibrate(floor, speed: 0.8).floorY == nil, "No calibration while walking")
        check(calibrate(floor, orientationStable: false).floorY == nil, "No calibration while rotating")
        check(calibrate([]).floorY == nil, "Missing floor is not a valid estimate")
        check(calibrate(Array(floor.prefix(10))).floorY == nil, "Insufficient floor support")
        check(calibrate(Array(repeating: SIMD3<Float>(0, 0, 1), count: 100)).floorY == nil, "One patch repeated is not broad support")
        check(calibrate([SIMD3<Float>(.nan, 0, 1), SIMD3<Float>(0, .infinity, 1)]).floorY == nil, "Invalid points excluded")
        let wall = floor.map { SIMD3<Float>($0.x, $0.z - 0.5, 1.2) }
        check(calibrate(wall).floorY == nil, "Wall cannot calibrate as floor")
        let narrowStrip = floor.map { SIMD3<Float>($0.x * 0.1, $0.y, $0.z) }
        check(calibrate(narrowStrip).floorY == nil, "Narrow strip cannot calibrate as floor")
        let raisedSurface = floor.map { $0 + SIMD3<Float>(0, 0.9, 0) }
        check(calibrate(raisedSurface).floorY == nil, "Surface too close to phone height rejected")
        let clutter = (0..<30).map { SIMD3<Float>(Float($0 % 5) * 0.1, Float($0 % 6) * 0.08, 1) }
        check(calibrate(floor + clutter).floorY != nil, "Floor fit tolerates clutter")
        var estimator = FloorEstimator()
        for index in 0...4 { estimator.update(points: floor, cameraPosition: camera, heading: heading, speed: 0, pitch: 60, orientationStable: true, timestamp: Double(index) * 0.1) }
        check(estimator.floorY == nil, "Single/brief view does not establish floor")
        estimator.update(points: floor, cameraPosition: camera, heading: heading, speed: 1, pitch: 60, orientationStable: true, timestamp: 0.5)
        check(estimator.progress == 0, "Motion resets pending calibration")
        for index in 6...10 { estimator.update(points: floor, cameraPosition: camera, heading: heading, speed: 0, pitch: 60, orientationStable: true, timestamp: Double(index) * 0.1) }
        check(estimator.floorY == nil, "Must reacquire full stable interval after motion")
        estimator.update(points: floor, cameraPosition: camera, heading: heading, speed: 0, pitch: 60, orientationStable: true, timestamp: 2)
        check(estimator.progress == 0, "Frame gap resets pending calibration")
        estimator = calibrate(floor)
        let calibratedY = estimator.floorY!
        let landing = floor.map { $0 - SIMD3<Float>(0, 0.35, 0) }
        for index in 0...12 { estimator.update(points: landing, cameraPosition: camera, heading: heading, speed: 0.8, pitch: 60, orientationStable: true, timestamp: 2 + Double(index) * 0.1) }
        check(estimator.floorY == calibratedY, "Lower landing never recalibrates while walking")
        check(abs((estimator.phoneHeight(at: camera + SIMD3<Float>(0, 0.2, 0)) ?? 0) - 1.4) < 0.02, "Raising phone changes height, not floor")

        let twoLevels = floor + floor.map { $0 - SIMD3<Float>(0, 0.3, 0) }
        let ambiguous = calibrate(twoLevels)
        check(ambiguous.floorY == nil && ambiguous.isAmbiguous, "Competing floor levels must not silently choose a landing")
        check(DetectionConfiguration.standard.canCalibrate(pitch: 45), "Calibration includes 45")
        check(DetectionConfiguration.standard.canCalibrate(pitch: 70), "Calibration includes 70")

        let geometry = CorridorGeometry()
        check(geometry.contains(SIMD3<Float>(0, 0.3, 2.5), cameraHeight: 1.2), "Point inside corridor")
        check(!geometry.contains(SIMD3<Float>(0.8, 0.3, 2.5), cameraHeight: 1.2), "Side obstacle excluded")
        check(!geometry.intersects(origin: camera, direction: SIMD3<Float>(0, 0, -1), cameraHeight: 1.2), "Behind-camera ray excluded")
        check(geometry.intersects(origin: camera, direction: SIMD3<Float>(0, -0.4, 1), cameraHeight: 1.2), "Downward ray intersects corridor")
        for degrees: Float in [0, 20, 45, 60] {
            let rotation = simd_quatf(angle: -degrees * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
            let pitch = CorridorGeometry.downPitch(forward: rotation.act(SIMD3<Float>(0, 0, -1)))
            check(abs(pitch - degrees) < 0.001, "Gravity-relative camera pitch")
        }
        check(geometry.guidance(pitch: 81) == "Raise phone slightly", "Extreme pitch guidance")
        func corridor(_ points: [SIMD3<Float>], expected: Int? = nil, cameraHeight: Float = 1.2) -> DetectionResult? {
            let samples = points.map { CorridorSample(position: SIMD3<Float>($0.x, $0.y - calibratedY, $0.z)) }
            return CorridorDetector.analyze(samples: samples, expected: expected ?? samples.count, speed: 0.8, cameraHeight: cameraHeight)
        }
        check(corridor(floor)!.assessment.hazard == .clear, "Regression: flat floor produces no walking warning")
        for height: Float in [0.8, 1, 1.2, 1.4, 1.7] {
            check(corridor(floor, cameraHeight: height)!.assessment.level == .low, "Regression: phone height does not turn floor into obstacle")
        }
        let noisyFloor = floor.enumerated().map { index, point in point + SIMD3<Float>(0, Float(index % 7 - 3) * 0.02, 0) }
        check(corridor(noisyFloor)!.assessment.hazard == .clear, "Ordinary floor depth noise excluded")
        let obstacle = (0..<6).map { SIMD3<Float>(Float($0) * 0.02, 0.5, 2.1) }
        check(corridor(floor + obstacle)!.assessment.stage == .early, "Real obstacle above floor still warns early")
        let closeObstacle = obstacle.map { SIMD3<Float>($0.x, $0.y, 0.8) }
        check(corridor(floor + closeObstacle)!.assessment.stage == .immediate, "Close obstacle retained")
        check(corridor(floor + obstacle + [SIMD3<Float>(0, 0.5, 0.4)])!.assessment.stage == .early, "One bad return cannot force high risk")
        let side = obstacle.map { $0 + SIMD3<Float>(1, 0, 0) }
        check(corridor(floor + side)!.assessment.hazard == .clear, "Outside-corridor wall ignored")
        let lower = obstacle.map { SIMD3<Float>($0.x, -0.35, 2.7) }
        check(corridor(floor + lower)!.assessment.hazard == .dropOff, "Lower ground with near support still warns")
        check(corridor(lower) == nil, "Missing supporting ground is unavailable, not clear")
        check(corridor(floor, expected: 1000) == nil, "Sparse coverage unavailable")
        check(corridor([]) == nil, "No coverage unavailable")
        // A close object should survive even when many more pixels see a far wall.
        let distantWall = (0..<200).map { SIMD3<Float>(Float($0 % 10) * 0.03, 0.5, 3.4) }
        check(corridor(floor + closeObstacle + distantWall)!.assessment.stage == .immediate, "Small close object against far wall is not lost to a global percentile")
        let veryClose = closeObstacle.map { SIMD3<Float>($0.x, $0.y, 0.15) }
        check(corridor(floor + veryClose)!.assessment.stage == .immediate, "Objects within 25 cm are not clipped away")
        let scattered = (0..<5).map { SIMD3<Float>(0, 0.5, 0.4 + Float($0) * 0.5) }
        check(corridor(floor + scattered)!.assessment.hazard == .clear, "Unrelated scattered returns are not a supported obstacle")
        check(corridor(floor)!.hasSufficientLookAhead == false, "Near floor alone cannot establish a clear 3m corridor")
        let fartherFloor = floor + floor.map { $0 + SIMD3<Float>(0, 0, 1.8) }
        check(corridor(fartherFloor)!.hasSufficientLookAhead, "Far supporting ground establishes look-ahead")
        check(corridor(side) == nil, "Seeing only off-corridor surfaces is not a clear path")
        let beyondDrop = (0..<6).map { SIMD3<Float>(Float($0) * 0.02, 0, 3.2) }
        let edgeRisk = corridor(floor + lower + beyondDrop)!.assessment
        check(edgeRisk.hazard == .dropOff && edgeRisk.distance < 2, "Ground beyond a drop must not push its edge farther away")

        // Exercise the same sensor-to-world ray helper used by WalkSession. Include
        // portrait sensor rotation and a cropped field of view, not just ideal points.
        let intrinsics = simd_float3x3(columns: (SIMD3<Float>(60, 0, 0), SIMD3<Float>(0, 60, 0), SIMD3<Float>(36, 24, 1)))
        for degrees: Float in [45, 55, 65, 70] {
            let tilt = simd_quatf(angle: -degrees * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
            let portrait = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
            var transform = simd_float4x4(tilt * portrait)
            transform.columns.3 = SIMD4<Float>(0, 1.2, 0, 1)
            let centerRay = DepthProjection.worldRay(sensorPixel: SIMD2<Float>(36, 24), intrinsics: intrinsics, cameraTransform: transform)
            check(abs(centerRay.y + sin(degrees * .pi / 180)) < 0.001, "Ray gravity sign at \(degrees) degrees")
            check(abs(centerRay.z + cos(degrees * .pi / 180)) < 0.001, "Ray camera forward sign")
            var projectedFloor: [SIMD3<Float>] = []
            for x in 14..<58 {
                for y in 0..<48 {
                    let ray = DepthProjection.worldRay(sensorPixel: SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5), intrinsics: intrinsics, cameraTransform: transform)
                    guard ray.y < -0.01 else { continue }
                    let axialDepth: Float = -1.2 / ray.y
                    projectedFloor.append(camera + ray * axialDepth)
                }
            }
            var fit = FloorEstimator()
            for tick in 0...12 {
                fit.update(points: projectedFloor, cameraPosition: camera, heading: SIMD3<Float>(0, 0, -1), speed: 0,
                    pitch: degrees, orientationStable: true, timestamp: Double(tick) * 0.1)
            }
            check(fit.floorY != nil, "Actual downward camera-ray floor calibration at \(degrees)")
            check(abs((fit.phoneHeight(at: camera) ?? 0) - 1.2) < 0.001, "Projected floor height remains correct")
            let samples = projectedFloor.map { CorridorSample(position: SIMD3<Float>($0.x, $0.y, -$0.z)) }
            let reading = CorridorDetector.analyze(samples: samples, expected: samples.count, speed: 0.8, cameraHeight: 1.2)!
            check(reading.assessment.hazard == .clear, "Tilted flat floor must not become obstacle")
            check(!reading.hasSufficientLookAhead, "Downward cropped view cannot promise 3m clear path")
            let closeSamples = veryClose.map { CorridorSample(position: $0) }
            let withObstacle = CorridorDetector.analyze(samples: samples + closeSamples, expected: samples.count + closeSamples.count, speed: 0.8, cameraHeight: 1.2)!
            check(withObstacle.assessment.stage == .immediate, "Limited far view must not discard a visible nearby hazard")
        }
        filter.reset()
        _ = filter.update(result(4), timestamp: 0)
        for tick in 1...4 { filtered = filter.update(result(4 - Float(tick) * 0.2), timestamp: Double(tick) * 0.1) }
        var changedSurface = result(3)
        changedSurface.supportPosition = SIMD3<Float>(0.4, 1.1, 3)
        check(filter.update(changedSurface, timestamp: 0.5).assessment.closingSpeed == nil, "Different support position rejects previous object's TTC")

        let combinedSamples = (floor + lower + veryClose).map { CorridorSample(position: $0) }
        let combined = CorridorDetector.analyze(samples: combinedSamples, expected: combinedSamples.count,
            speed: 0.8, cameraHeight: 1.2, safetyProfile: vision)!
        check(combined.assessment.hazard == .tooClose, "Detector preserves absolute proximity arbitration")
        let farObstacle = obstacle.map { SIMD3<Float>($0.x, $0.y, 3.2) }
        let farSamples = (floor + farObstacle).map { CorridorSample(position: $0) }
        let earlyVision = CorridorDetector.analyze(samples: farSamples, expected: farSamples.count,
            speed: 0.8, cameraHeight: 1.2, safetyProfile: vision)!
        check(earlyVision.assessment.stage == .early, "Detector applies earlier profile warning")
        filter.reset()
        _ = filter.update(earlyVision, timestamp: 0)
        let retained = filter.update(earlyVision, timestamp: 0.1)
        check(retained.assessment.safetyProfile == vision, "Smoothing retains profile")

        let grid = DepthGridSampler.sample(DepthFrame(width: 3, height: 3, meters: [1, 2, 3, 4, .nan, 6, 7, 8, 9]))
        check(grid.cell(row: .mid, column: .center).minMeters == nil, "Original grid invalid cell")
        check(grid.cell(row: .nearGround, column: .center).minMeters == 8, "Original grid indexing")
        print("Passed \(checks) floor calibration, detection, and warning checks.")
    }
}
