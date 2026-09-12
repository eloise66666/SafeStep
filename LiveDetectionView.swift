import SwiftUI

extension RiskLevel {
    var color: Color {
        switch self {
        case .low: return .stepAccent
        case .medium: return Color(red: 0.54, green: 0.35, blue: 0)
        case .high: return Color(red: 0.71, green: 0.14, blue: 0.09)
        }
    }
    var icon: String { self == .low ? "checkmark.shield" : self == .medium ? "exclamationmark.triangle" : "hand.raised.fill" }
}

struct LiveDetectionView: View {
    @StateObject private var model: WalkSession

    init(safetyProfile: SafetyProfile = .general) {
        _model = StateObject(wrappedValue: WalkSession(safetyProfile: safetyProfile))
    }
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDebug = false

    private var tint: Color {
        guard model.safetyProfile.visualAlertsEnabled, let risk = model.result?.assessment else { return .gray }
        return risk.level == .low && !model.hasFullLookAhead ? .gray : risk.level.color
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    Label("LIVE DETECTION", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.bold)).tracking(1.5).foregroundStyle(Color.stepAccent)
                    Spacer()
                    Text(model.result?.assessment.movement.rawValue ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
                camera
                Text(model.safetyProfile.kind.rawValue).font(.subheadline)
                if model.safetyProfile.visualAlertsEnabled || model.result == nil { statusCard }
                if model.safetyProfile.visualAlertsEnabled {
                    HStack(spacing: 12) {
                        metric("OBSTACLE AHEAD", value: model.result.flatMap { $0.assessment.hazard == .clear ? nil : $0.assessment.distanceText } ?? "—", icon: "arrow.left.and.right")
                        metric("HEIGHT ABOVE FLOOR", value: model.groundHeight.map { String(format: "%.2f m", $0) } ?? "—", icon: "arrow.up.and.down")
                    }
                }
                HStack {
                    Toggle(isOn: $model.voiceEnabled) { Label("Voice", systemImage: "speaker.wave.2") }
                    Toggle(isOn: $model.hapticsEnabled) { Label("Touch", systemImage: "iphone.radiowaves.left.and.right") }
                }
                .font(.caption).tint(.stepAccent)
                Text(model.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Text("Keep PathGuard visible. Detection pauses when you switch apps or lock the phone.")
                    .font(.caption).foregroundStyle(.secondary)
                Button { showDebug = true } label: {
                    HStack {
                        Label("Sensor details", systemImage: "slider.horizontal.3")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }.font(.subheadline).padding(18).background(Color.stepCard, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .foregroundStyle(Color.stepInk)
        .background(Color.stepBackground)
        .safeAreaInset(edge: .bottom) {
            Button {
                if model.isEnabled { model.stop() } else { model.start() }
            } label: {
                Label(model.isEnabled ? "Pause walk" : "Resume walk", systemImage: model.isEnabled ? "pause.fill" : "play.fill")
                    .font(.headline).frame(maxWidth: .infinity).padding(18)
                    .foregroundStyle(Color.stepBackground).background(Color.stepAccent, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, 20).padding(.vertical, 12).background(Color.stepBackground)
        }
        .tint(.stepAccent)
        .toolbarBackground(Color.stepBackground, for: .navigationBar)
        .navigationTitle("Safe walk")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.light)
        .sheet(isPresented: $showDebug) { DebugPanel(model: model) }
        .onAppear { model.start() }
        .onDisappear { if scenePhase == .active { model.stop() } }
        .onChange(of: scenePhase) { model.setSceneActive($0 == .active) }
    }

    private var camera: some View {
        GeometryReader { geometry in
            ZStack {
                CameraPreview(model: model)
                if model.safetyProfile.visualAlertsEnabled && !model.samplingMask.isEmpty {
                    Path { path in
                        for point in model.samplingMask {
                            path.addRect(CGRect(x: (point.x - 0.5 / 48) * geometry.size.width,
                                y: (point.y - 0.5 / 72) * geometry.size.height,
                                width: geometry.size.width / 48, height: geometry.size.height / 72))
                        }
                    }.fill(tint.opacity(0.2))
                }
                VStack {
                    HStack {
                        Label(model.isRunning ? "SCANNING" : "PAUSED", systemImage: model.isRunning ? "record.circle" : "pause.circle")
                        Spacer()
                        Image(systemName: "viewfinder")
                    }
                    .font(.caption2.weight(.bold)).foregroundStyle(.white).padding(12).background(.black.opacity(0.45))
                    Spacer()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .onAppear { model.viewport = geometry.size }
            .onChange(of: geometry.size) { model.viewport = $0 }
        }
        .frame(height: 300)
        .accessibilityLabel("Rear camera preview with walking corridor")
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let assessment = model.result?.assessment, assessment.stage != .clear || model.hasFullLookAhead {
                HStack {
                    Label(assessment.stage.title.uppercased(), systemImage: assessment.level.icon)
                        .font(.caption.weight(.bold)).tracking(1)
                    Spacer()
                }
                Text(assessment.stage == .clear ? "Path clear" : assessment.hazard.rawValue).font(.title2.weight(.bold))
                Text(assessment.stage == .clear ? Hazard.clear.advice : assessment.advice).font(.subheadline)
                if assessment.heldStage != nil { Text("Holding warning while the reading stabilizes").font(.caption2) }
            } else {
                Label(model.isRunning ? (model.groundHeight == nil ? "FINDING FLOOR" : "LIMITED VIEW") : "DETECTION PAUSED", systemImage: "viewfinder")
                    .font(.headline)
                Text(model.isRunning ? model.status : "Resume when you’re ready to scan.")
                    .font(.subheadline)
                if model.isRunning && model.groundHeight == nil {
                    ProgressView(value: model.calibrationProgress).tint(.stepAccent)
                    Text("Camera tilt: \(model.pitchDegrees, specifier: "%.0f")° downward")
                        .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .foregroundStyle(tint).background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(tint.opacity(0.25)))
        .accessibilityElement(children: .combine)
    }

    private func metric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit()).minimumScaleFactor(0.7).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color.stepCard, in: RoundedRectangle(cornerRadius: 16))
    }
}
