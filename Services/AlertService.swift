import AVFoundation
import CoreHaptics
import UIKit

final class AlertService: NSObject, AVSpeechSynthesizerDelegate {
    private let safetyProfile: SafetyProfile
    private let configuration: DetectionConfiguration
    private let speech = AVSpeechSynthesizer()
    private var engine: CHHapticEngine?
    private var players: [String: CHHapticPatternPlayer] = [:]
    private var player: CHHapticPatternPlayer?
    private var fallbackPulses: [DispatchWorkItem] = []
    private var lastHaptic = Date.distantPast
    private var lastSpeech = Date.distantPast
    private var lastLevel: RiskLevel = .low
    private var lastSpokenHazard: Hazard?
    var voiceEnabled = true
    var hapticsEnabled = true
    private(set) var lastHapticError: String?

    init(configuration: DetectionConfiguration = .standard, safetyProfile: SafetyProfile = .general) {
        self.safetyProfile = safetyProfile
        self.voiceEnabled = safetyProfile.voiceEnabled
        self.configuration = configuration
        super.init()
        speech.delegate = self
    }

    var hardwareDescription: String {
        #if targetEnvironment(simulator)
        return "Simulator: vibration cannot be tested. Run on a physical iPhone."
        #else
        return CHHapticEngine.capabilitiesForHardware().supportsHaptics
            ? "Haptic hardware available. Confirm pulse strength on this physical device."
            : "This device has no Core Haptics support. Use a supported physical iPhone."
        #endif
    }

    func update(_ assessment: RiskAssessment) {
        guard assessment.level != .low else {
            silence()
            lastLevel = .low
            return
        }
        let high = assessment.level == .high
        let escalation = high && lastLevel != .high
        let interval = safetyProfile.repeatFrequency
        let hapticReady = Date().timeIntervalSince(lastHaptic) >= interval ||
            (escalation && Date().timeIntervalSince(lastHaptic) >= configuration.hapticEscalationCooldown)
        if hapticsEnabled && hapticReady {
            lastHaptic = Date()
            playHaptic(level: assessment.level)
        }
        let speechReady = Date().timeIntervalSince(lastSpeech) >= safetyProfile.repeatFrequency || escalation ||
            (lastSpokenHazard != assessment.hazard && Date().timeIntervalSince(lastSpeech) >= configuration.speechHazardCooldown)
        if voiceEnabled && (!safetyProfile.voiceOnCriticalOnly || high) && speechReady {
            let text = assessment.stage == .immediate
                ? "Immediate danger. \(assessment.hazard.rawValue). Stop walking."
                : "\(assessment.stage.title). \(assessment.hazard.rawValue), \(assessment.distanceText) ahead. \(assessment.advice)"
            speak(text)
            lastSpokenHazard = assessment.hazard
        }
        lastLevel = assessment.level
    }

    /// Explicit debug action tests the pattern and speech, independent of alert toggles.
    func test(_ level: RiskLevel) -> String {
        stop()
        playHaptic(level: level)
        speak(level == .high ? "Test. Immediate danger. Stop walking." : "Test. Warning. Obstacle ahead.")
        lastHaptic = Date()
        return hardwareDescription + (lastHapticError.map { " Core Haptics error: \($0). Using system feedback." } ?? "")
    }

    private func speak(_ text: String) {
        // Speech remains audible with the silent switch; respect the user's Voice toggle.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.48
        speech.speak(utterance)
        lastSpeech = Date()
    }

    private func playHaptic(level: RiskLevel) {
        guard level != .low, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        let high = level == .high
        do {
            if engine == nil {
                let newEngine = try CHHapticEngine()
                newEngine.isAutoShutdownEnabled = true
                newEngine.playsHapticsOnly = true
                newEngine.resetHandler = { [weak self] in
                    DispatchQueue.main.async {
                        self?.players.removeAll()
                        self?.player = nil
                    }
                }
                engine = newEngine
            }
            guard let engine else { return }
            try engine.start()
            try? player?.stop(atTime: CHHapticTimeImmediate)
            let key = level.rawValue
            if players[key] == nil {
                let duration = (high ? configuration.highPulseDuration : configuration.mediumPulseDuration)
                let gap = high ? configuration.highPulseGap : configuration.mediumPulseGap
                let events = (0..<(high ? 3 : 2)).map { index in
                    CHHapticEvent(eventType: .hapticContinuous, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: safetyProfile.haptics.intensity),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: high ? 1 : 0.7)
                    ], relativeTime: Double(index) * (duration + gap), duration: duration)
                }
                players[key] = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            }
            player = players[key]
            try player?.start(atTime: CHHapticTimeImmediate)
            lastHapticError = nil
        } catch {
            lastHapticError = error.localizedDescription
            players.removeAll()
            // Reuse the engine; a reset or subsequent start may recover it.
            fallbackPulses.forEach { $0.cancel() }
            fallbackPulses = (0..<(high ? 3 : 2)).map { index in
                let strength = safetyProfile.haptics
                let work = DispatchWorkItem { UIImpactFeedbackGenerator(style: strength == .light ? .light : strength == .medium ? .medium : .heavy).impactOccurred(intensity: CGFloat(strength.intensity)) }
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.3, execute: work)
                return work
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func silence() {
        if speech.isSpeaking {
            speech.stopSpeaking(at: .immediate)
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        try? player?.stop(atTime: CHHapticTimeImmediate)
        fallbackPulses.forEach { $0.cancel() }
        fallbackPulses.removeAll()
    }

    func stop() {
        silence()
        lastSpokenHazard = nil
        lastSpeech = .distantPast
        lastHaptic = .distantPast
        lastLevel = .low
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
