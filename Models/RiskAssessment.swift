import Foundation
import simd

/// Prototype tuning values, not certified stopping distances. All distances are metres.
struct DetectionConfiguration: Equatable {
    static let standard = DetectionConfiguration()
    var earlyDistance: Float = 3
    var warningDistance: Float = 2
    var immediateDistance: Float = 1.2
    var stationaryOffset: Float = -0.2
    var fastOffset: Float = 0.6
    var stationarySpeed: Float = 0.15
    var fastSpeed: Float = 1.6
    var earlyTTC: Float = 3
    var warningTTC: Float = 2
    var immediateTTC: Float = 1
    var minimumClosingSpeed: Float = 0.2
    var maximumClosingSpeed: Float = 4
    var closingSampleCount = 4
    var maximumSampleGap: Double = 0.35
    var distanceReleaseAlpha: Float = 0.35
    var releaseMargin: Float = 0.2
    var releaseDelay: Double = 0.6
    var minimumCoverage: Float = 0.55
    var corridorHalfWidth: Float = 0.45
    var corridorNear: Float = 0.05
    var minimumObstacleHeight: Float = 0.18
    var dropHeight: Float = 0.18
    var groundTolerance: Float = 0.12
    var groundSupportDistance: Float = 1.5
    var minimumHazardSamples = 5
    var maximumDownPitch: Float = 80
    var maximumUpPitch: Float = 20
    var orientationTimeConstant: Float = 0.2
    var mediumCooldown: Double = 2.5
    var highCooldown: Double = 1.6
    var speechCooldown: Double = 6
    var mediumPulseDuration: Double = 0.22
    var mediumPulseGap: Double = 0.18
    var highPulseDuration: Double = 0.3
    var highPulseGap: Double = 0.12
    var hapticEscalationCooldown: Double = 0.3
    var speechHazardCooldown: Double = 2
    var maximumClosingDeviation: Float = 0.5
    var releaseTTCMargin: Float = 0.3
    var corridorBelowGround: Float = 1
    var corridorAboveCamera: Float = 0.3
    var minimumCameraHeight: Float = 0.5
    var maximumCameraHeight: Float = 2.2

    var calibrationMinimumPitch: Float = 45
    var calibrationMaximumPitch: Float = 70
    var calibrationSpeed: Float = 0.08
    var calibrationAngularSpeed: Float = 10 // degrees per second
    var calibrationDuration: Double = 1.0
    var floorFitTolerance: Float = 0.035
    var floorMinimumSamples = 40
    var floorMinimumFraction: Float = 0.4
    var floorMinimumWidth: Float = 0.4
    var floorMinimumLength: Float = 0.5
    var floorMinimumCells = 8
    var floorCellSize: Float = 0.2
    var floorCalibrationNear: Float = 0.3
    var floorCalibrationFar: Float = 2
    var competingFloorRatio: Float = 0.75
    var hazardSupportSpan: Float = 0.25
    var supportTrackingTolerance: Float = 0.15
    var lookAheadMargin: Float = 0.15
    var calibrationPitchText: String {
        String(format: "%.0f–%.0f°", calibrationMinimumPitch, calibrationMaximumPitch)
    }
    func canCalibrate(pitch: Float) -> Bool {
        pitch >= calibrationMinimumPitch && pitch <= calibrationMaximumPitch
    }

    func offset(movement: Movement) -> Float {
        (movement == .stationary ? stationaryOffset : movement == .fast ? fastOffset : 0)
    }
    func threshold(for stage: WarningStage, movement: Movement) -> Float {
        switch stage {
        case .clear: return .infinity
        case .early: return earlyDistance + offset(movement: movement)
        case .warning: return warningDistance + offset(movement: movement)
        // Never relax the immediate-proximity boundary for stationary users.
        case .immediate: return immediateDistance + max(0, offset(movement: movement))
        }
    }
    var searchDistance: Float { earlyDistance + max(0, fastOffset) + releaseMargin }
}

enum WarningStage: Int, Comparable {
    case clear, early, warning, immediate
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    var title: String {
        switch self {
        case .clear: return "Path clear"
        case .early: return "Early caution"
        case .warning: return "Warning"
        case .immediate: return "Immediate danger"
        }
    }
    var level: RiskLevel { self == .clear ? .low : self == .immediate ? .high : .medium }
}

enum Movement: String, CaseIterable {
    case stationary = "Stationary", walking = "Walking", fast = "Moving quickly"
    init(speed: Float, configuration: DetectionConfiguration = .standard) {
        self = speed < configuration.stationarySpeed ? .stationary : speed < configuration.fastSpeed ? .walking : .fast
    }
}

enum Hazard: String {
    case clear = "Path clear"
    case obstacle = "Obstacle ahead"
    case dropOff = "Possible drop-off / stairs down"
    case tooClose = "Too close"
    var advice: String {
        switch self {
        case .clear: return "Stay aware of your surroundings"
        case .obstacle: return "Slow down. Check the path ahead."
        case .dropOff: return "Stop. Check the ground ahead."
        case .tooClose: return "Stop walking. Look ahead."
        }
    }
}

enum RiskLevel: String { case low = "Low", medium = "Medium", high = "High" }

struct RiskAssessment: Equatable {
    let hazard: Hazard
    let distance: Float
    let movement: Movement
    var configuration: DetectionConfiguration = .standard
    var closingSpeed: Float? = nil
    var heldStage: WarningStage? = nil
    var timeToCollision: Float? {
        guard let closingSpeed, closingSpeed >= configuration.minimumClosingSpeed else { return nil }
        return distance / closingSpeed
    }
    var stage: WarningStage {
        if let heldStage { return heldStage }
        guard hazard != .clear else { return .clear }
        if hazard == .tooClose { return .immediate }
        for stage in [WarningStage.immediate, .warning, .early] {
            let ttcLimit = stage == .immediate ? configuration.immediateTTC : stage == .warning ? configuration.warningTTC : configuration.earlyTTC
            if distance < configuration.threshold(for: stage, movement: movement)
                || (stage == .early && distance == configuration.threshold(for: stage, movement: movement))
                || (timeToCollision.map { $0 < ttcLimit } ?? false) { return stage }
        }
        return .clear
    }
    var advice: String {
        if stage == .immediate { return "Stop walking. Check the path ahead." }
        if stage == .early { return "Hazard ahead. Look up and prepare to slow down." }
        return hazard.advice
    }
    var level: RiskLevel {
        stage.level
    }
    var distanceText: String { String(format: "%.1f m", distance) }
}

struct DetectionResult {
    let assessment: RiskAssessment
    let coverage: Float
    let nearbyFraction: Float
    var observedGroundDistance: Float = 0
    var supportPosition: SIMD3<Float>? = nil
    var hasSufficientLookAhead: Bool {
        observedGroundDistance >= assessment.configuration.threshold(for: .early, movement: assessment.movement)
            - assessment.configuration.lookAheadMargin
    }
}

/// Stateful, quick attack / slow release filtering. Never carries warnings across data loss.
struct DetectionStabilizer {
    private var previous: RiskAssessment?
    private var previousRaw: Float?
    private var previousSupport: SIMD3<Float>?
    private var lastTime: Double?
    private var rates: [Float] = []
    private var releaseStarted: Double?

    mutating func reset() { self = DetectionStabilizer() }

    mutating func update(_ result: DetectionResult, timestamp: Double, headingStable: Bool = true) -> DetectionResult {
        var risk = result.assessment
        let config = risk.configuration
        let dt = lastTime.map { timestamp - $0 } ?? 0
        let sameSurface = previous.map {
            $0.hazard == risk.hazard || ([$0.hazard, risk.hazard].allSatisfy { $0 == .obstacle || $0 == .tooClose })
        } ?? false
        let supportStable: Bool
        if let old = previousSupport, let new = result.supportPosition {
            supportStable = abs(old.x - new.x) <= config.supportTrackingTolerance
                && abs(old.y - new.y) <= config.supportTrackingTolerance
        } else { supportStable = false }
        let continuous = dt > 0 && dt <= config.maximumSampleGap && headingStable && sameSurface
        if continuous, let oldRaw = previousRaw, risk.hazard != .clear {
            let rate = (oldRaw - risk.distance) / Float(dt)
            if supportStable && abs(rate) <= config.maximumClosingSpeed {
                rates.append(rate)
                rates = Array(rates.suffix(config.closingSampleCount))
            } else { rates.removeAll() }
            if rates.count == config.closingSampleCount {
                let mean = rates.reduce(0, +) / Float(rates.count)
                // Reject rapidly changing surfaces and noisy derivatives, including turns.
                if rates.allSatisfy({ abs($0 - mean) < config.maximumClosingDeviation }), mean >= config.minimumClosingSpeed {
                    risk.closingSpeed = mean
                }
            }
            if let previous {
                risk = RiskAssessment(hazard: risk.hazard,
                    distance: min(risk.distance, previous.distance + config.distanceReleaseAlpha * (risk.distance - previous.distance)),
                    movement: risk.movement, configuration: config, closingSpeed: risk.closingSpeed)
            }
        } else { rates.removeAll() }
        previousSupport = result.supportPosition
        previousRaw = result.assessment.distance
        lastTime = timestamp
        if let old = previous, dt > 0, dt <= config.maximumSampleGap, risk.stage < old.stage {
            let boundary = config.threshold(for: old.stage, movement: risk.movement)
            let ttcBoundary = old.stage == .immediate ? config.immediateTTC : old.stage == .warning ? config.warningTTC : config.earlyTTC
            let safelyBeyond = risk.hazard == .clear ||
                (risk.distance >= boundary + config.releaseMargin && (risk.timeToCollision.map { $0 >= ttcBoundary + config.releaseTTCMargin } ?? true))
            if safelyBeyond {
                if releaseStarted == nil { releaseStarted = timestamp }
            } else { releaseStarted = nil }
            if releaseStarted.map({ timestamp - $0 < config.releaseDelay }) ?? true {
                risk = RiskAssessment(hazard: risk.hazard == .clear ? old.hazard : risk.hazard,
                    distance: risk.distance, movement: risk.movement,
                    configuration: config, closingSpeed: risk.closingSpeed, heldStage: old.stage)
            } else { releaseStarted = nil }
        } else { releaseStarted = nil }
        previous = risk
        return DetectionResult(assessment: risk, coverage: result.coverage, nearbyFraction: result.nearbyFraction, observedGroundDistance: result.observedGroundDistance, supportPosition: result.supportPosition)
    }
}
