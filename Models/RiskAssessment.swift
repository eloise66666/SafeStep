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

enum Hazard: String, CaseIterable {
    case clear = "Path clear"
    case stairs = "Stairs ahead"
    case obstacle = "Obstacle ahead"
    case dropOff = "Possible drop-off / stairs down"
    case tooClose = "Too close"
    var advice: String {
        switch self {
        case .clear: return "Stay aware of your surroundings"
        case .obstacle: return "Slow down. Check the path ahead."
        case .stairs: return "Slow down. Check the steps ahead."
        case .dropOff: return "Stop. Check the ground ahead."
        case .tooClose: return "Stop walking. Look ahead."
        }
    }
}

enum ProfileKind: String, CaseIterable, Identifiable {
    case vision = "Vision Impaired", mobility = "Mobility Impaired"
    case general = "General / Distracted", custom = "Custom"
    var id: String { rawValue }
}

enum HapticStrength: String, CaseIterable {
    case light = "Light", medium = "Medium", strong = "Strong"
    var intensity: Float { self == .light ? 0.35 : self == .medium ? 0.65 : 1 }
}

struct SafetyProfile: Equatable {
    var kind: ProfileKind = .general
    var warningDistanceMultiplier: Float = 1 {
        didSet { warningDistanceMultiplier = warningDistanceMultiplier.isFinite ? min(2, max(0.5, warningDistanceMultiplier)) : 1 }
    }
    private var priorities: [Hazard: Int] = [.obstacle: 3, .stairs: 3, .dropOff: 3, .tooClose: 5]
    var haptics: HapticStrength = .medium
    var voiceEnabled = true
    var visualAlertsEnabled = true
    var voiceOnCriticalOnly = true
    /// Seconds between repeated alerts; urgent escalation can interrupt this interval.
    var repeatFrequency: Double = 2.5 {
        didSet { repeatFrequency = repeatFrequency.isFinite ? min(10, max(1, repeatFrequency)) : 2.5 }
    }
    static let general = SafetyProfile()
    func priority(for hazard: Hazard) -> Int { priorities[hazard] ?? 1 }
    mutating func setPriority(_ value: Int, for hazard: Hazard) { priorities[hazard] = min(5, max(1, value)) }
    static func preset(_ kind: ProfileKind) -> SafetyProfile {
        var profile = SafetyProfile()
        profile.kind = kind
        if kind == .vision || kind == .mobility {
            profile.warningDistanceMultiplier = 1.5
            profile.haptics = .strong
            profile.voiceOnCriticalOnly = false
            profile.visualAlertsEnabled = kind != .vision
            profile.repeatFrequency = 1.6
            profile.setPriority(5, for: .dropOff)
            profile.setPriority(5, for: .stairs)
            profile.setPriority(kind == .vision ? 5 : 3, for: .obstacle)
        }
        return profile
    }
}

extension Hazard {
    var baseDistance: Float {
        switch self {
        case .clear: return 0
        case .obstacle: return 1.5
        case .stairs, .dropOff: return 2
        case .tooClose: return 0.8
        }
    }
}

struct HazardObservation {
    let hazard: Hazard
    let distance: Float
}

enum RiskEngine {
    static func assess(hazard: Hazard, distance: Float, movementState: Movement,
                       safetyProfile: SafetyProfile, configuration: DetectionConfiguration = .standard) -> RiskAssessment {
        RiskAssessment(hazard: hazard, distance: distance, movement: movementState,
                       configuration: configuration, safetyProfile: safetyProfile)
    }

    /// Absolute proximity first, then danger stage, user priority, and nearest distance.
    static func assess(hazards: [HazardObservation], movementState: Movement,
                       safetyProfile: SafetyProfile, configuration: DetectionConfiguration = .standard) -> RiskAssessment {
        let active = hazards.filter { $0.hazard != .clear && $0.distance.isFinite && $0.distance >= 0 }
            .map { assess(hazard: $0.hazard, distance: $0.distance, movementState: movementState,
                          safetyProfile: safetyProfile, configuration: configuration) }
            .filter { $0.stage != .clear }
        return active.sorted {
            if ($0.hazard == .tooClose) != ($1.hazard == .tooClose) { return $0.hazard == .tooClose }
            if $0.stage != $1.stage { return $0.stage > $1.stage }
            let left = safetyProfile.priority(for: $0.hazard), right = safetyProfile.priority(for: $1.hazard)
            if left != right { return left > right }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.hazard.rawValue < $1.hazard.rawValue
        }.first ?? assess(hazard: .clear, distance: configuration.searchDistance,
                          movementState: movementState, safetyProfile: safetyProfile, configuration: configuration)
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
    var safetyProfile: SafetyProfile = .general
    var personalizedDistanceThreshold: Float { hazard.baseDistance * safetyProfile.warningDistanceMultiplier }
    var targetHazard: Hazard { hazard }
    /// Bounded score: stage determines the band; priority and proximity refine it.
    var totalRiskScore: Float {
        guard stage != .clear else { return 0 }
        if hazard == .tooClose { return 100 }
        let base: Float = stage == .immediate ? 75 : stage == .warning ? 45 : 15
        let proximity = max(0, min(1, 1 - distance / max(0.01, personalizedDistanceThreshold)))
        return min(99, base + Float(safetyProfile.priority(for: hazard)) * 3 + proximity * 9)
    }
    func threshold(for stage: WarningStage) -> Float {
        let base = personalizedDistanceThreshold
        switch stage {
        case .clear: return .infinity
        case .early: return base * 1.5 + configuration.offset(movement: movement)
        case .warning: return base + configuration.offset(movement: movement)
        case .immediate: return base * 0.6 + max(0, configuration.offset(movement: movement))
        }
    }
    var timeToCollision: Float? {
        guard let closingSpeed, closingSpeed >= configuration.minimumClosingSpeed else { return nil }
        return distance / closingSpeed
    }
    var stage: WarningStage {
        if let heldStage { return heldStage }
        guard hazard != .clear, distance.isFinite, distance >= 0 else { return .clear }
        if hazard == .tooClose { return .immediate }
        for stage in [WarningStage.immediate, .warning, .early] {
            let ttcLimit = stage == .immediate ? configuration.immediateTTC : stage == .warning ? configuration.warningTTC : configuration.earlyTTC
            if distance < threshold(for: stage)
                || (stage == .early && distance == threshold(for: stage))
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
        observedGroundDistance >= max(Hazard.obstacle.baseDistance, Hazard.dropOff.baseDistance) * assessment.safetyProfile.warningDistanceMultiplier * 1.5 + assessment.configuration.offset(movement: assessment.movement)
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
                    movement: risk.movement, configuration: config, closingSpeed: risk.closingSpeed, safetyProfile: risk.safetyProfile)
            }
        } else { rates.removeAll() }
        previousSupport = result.supportPosition
        previousRaw = result.assessment.distance
        lastTime = timestamp
        if let old = previous, dt > 0, dt <= config.maximumSampleGap, risk.stage < old.stage {
            let boundary = old.threshold(for: old.stage)
            let ttcBoundary = old.stage == .immediate ? config.immediateTTC : old.stage == .warning ? config.warningTTC : config.earlyTTC
            let safelyBeyond = risk.hazard == .clear ||
                (risk.distance >= boundary + config.releaseMargin && (risk.timeToCollision.map { $0 >= ttcBoundary + config.releaseTTCMargin } ?? true))
            if safelyBeyond {
                if releaseStarted == nil { releaseStarted = timestamp }
            } else { releaseStarted = nil }
            if releaseStarted.map({ timestamp - $0 < config.releaseDelay }) ?? true {
                risk = RiskAssessment(hazard: risk.hazard == .clear ? old.hazard : risk.hazard,
                    distance: risk.distance, movement: risk.movement,
                    configuration: config, closingSpeed: risk.closingSpeed, heldStage: old.stage, safetyProfile: risk.safetyProfile)
            } else { releaseStarted = nil }
        } else { releaseStarted = nil }
        previous = risk
        return DetectionResult(assessment: risk, coverage: result.coverage, nearbyFraction: result.nearbyFraction, observedGroundDistance: result.observedGroundDistance, supportPosition: result.supportPosition)
    }
}
