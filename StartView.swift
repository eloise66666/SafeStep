import SwiftUI

extension Color {
    static let stepBackground = Color(red: 0.96, green: 0.97, blue: 0.94)
    static let stepCard = Color.white
    static let stepAccent = Color(red: 0.14, green: 0.24, blue: 0.06)
    static let stepInk = Color(red: 0.12, green: 0.18, blue: 0.08)
    static let stepSage = Color(red: 0.65, green: 0.79, blue: 0.41)
    static let stepLogoSurface = Color(red: 0.86, green: 0.90, blue: 0.80)
}

struct StartView: View {
    @State private var selectedProfile: ProfileKind = .general
    @State private var customProfile = SafetyProfile.preset(.custom)
    @State private var showCustomSettings = false
    private var profile: SafetyProfile { selectedProfile == .custom ? customProfile : .preset(selectedProfile) }
    var body: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 24) {
                Spacer()
                // Frame the original artwork's transparent margins without modifying the asset.
                Image("BrandLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 480, height: 480)
                    .offset(x: -3.6, y: 28)
                    .frame(width: 270, height: 156)
                    .clipped()
                    .background(Color.stepLogoSurface, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.stepSage.opacity(0.45), lineWidth: 1))
                    .accessibilityLabel("PathGuard logo")
                Text("PathGuard").font(.largeTitle.bold())
                Text("A heads-up for what’s ahead.")
                    .font(.title2).foregroundStyle(Color.stepAccent)
                Text("Stand still on flat ground. Tilt the camera \(DetectionConfiguration.standard.calibrationPitchText) downward and hold it steady while PathGuard measures the floor.")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Safety profile", selection: $selectedProfile) {
                    ForEach(ProfileKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                if selectedProfile == .custom {
                    Button("Customize profile") { showCustomSettings = true }
                }
                Text("Warnings: \(profile.warningDistanceMultiplier, specifier: "%.1f")× distance · \(profile.haptics.rawValue) haptics")
                    .font(.caption)
                NavigationLink { LiveDetectionView(safetyProfile: profile) } label: {
                    HStack { Text("Start scanning"); Spacer(); Image(systemName: "arrow.right") }
                        .font(.headline).padding(20).foregroundStyle(Color.stepBackground)
                        .background(Color.stepAccent, in: RoundedRectangle(cornerRadius: 18))
                }
                .disabled(!WalkSession.supportsLiDAR)
                .opacity(WalkSession.supportsLiDAR ? 1 : 0.45)
                Text(WalkSession.supportsLiDAR ? "Keep PathGuard visible while scanning. Keep looking ahead; this prototype can miss hazards." : "Live scanning requires a LiDAR-equipped iPhone or iPad.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .foregroundStyle(Color.stepInk)
            .background(Color.stepBackground)
            .preferredColorScheme(.light)
            }
            .sheet(isPresented: $showCustomSettings) { CustomProfileSettings(profile: $customProfile) }
        }
        .tint(.stepAccent)
    }
}

#Preview { StartView() }

struct CustomProfileSettings: View {
    @Binding var profile: SafetyProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Warning distance") {
                    Text("Multiplier: \(profile.warningDistanceMultiplier, specifier: "%.1f")×")
                    Slider(value: $profile.warningDistanceMultiplier, in: 0.5...2, step: 0.1)
                        .accessibilityLabel("Warning distance multiplier")
                }
                Section("Hazard priorities · 5 is highest") {
                    ForEach([Hazard.obstacle, .stairs, .dropOff, .tooClose], id: \.self) { hazard in
                        Stepper("\(hazard.rawValue): \(profile.priority(for: hazard))", value: Binding(
                            get: { profile.priority(for: hazard) },
                            set: { profile.setPriority($0, for: hazard) }), in: 1...5)
                    }
                    Text("Too close always takes priority.").font(.caption)
                }
                Section("Alerts") {
                    Picker("Haptic strength", selection: $profile.haptics) {
                        ForEach(HapticStrength.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Voice alerts", isOn: $profile.voiceEnabled)
                    Toggle("Voice on critical hazards only", isOn: $profile.voiceOnCriticalOnly)
                        .disabled(!profile.voiceEnabled)
                    Toggle("Visual alerts", isOn: $profile.visualAlertsEnabled)
                    Stepper("Repeat every \(profile.repeatFrequency, specifier: "%.1f") seconds",
                            value: $profile.repeatFrequency, in: 1...10, step: 0.5)
                }
            }
            .navigationTitle("Custom profile")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
