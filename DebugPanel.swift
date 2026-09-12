import SwiftUI

struct DebugPanel: View {
    @ObservedObject var model: WalkSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Floor measurement") {
                    row("Phone height above floor", model.groundHeight.map { String(format: "%.2f m", $0) } ?? "Not calibrated")
                    row("Downward camera tilt", String(format: "%.0f°", model.pitchDegrees))
                    Text("Stand still on flat ground with the camera aimed \(model.configuration.calibrationPitchText) downward. Calibration requires a broad, flat patch visible for about one second. Height is vertical distance, not the slanted camera-to-floor range.")
                        .font(.caption)
                    Button("Measure floor again") { model.recalibrateFloor() }
                        .disabled(!model.isRunning)
                }
                if let result = model.result {
                    Section("Live reading") {
                        row("Warning", result.assessment.stage == .clear && !model.hasFullLookAhead ? "Limited view" : result.assessment.stage.title)
                        row("Observed floor reach", String(format: "%.1f m", model.observedGroundDistance))
                        row("Movement", result.assessment.movement.rawValue)
                        row("Reliable depth", String(format: "%.0f%%", result.coverage * 100))
                        row("Closing speed", result.assessment.closingSpeed.map { String(format: "%.2f m/s", $0) } ?? "Not reliable yet")
                        row("Time to collision", result.assessment.timeToCollision.map { String(format: "%.1f s", $0) } ?? "Using distance")
                    }
                }
                Section("Test warnings while stationary") {
                    Text(model.alerts.hardwareDescription).font(.caption)
                    Button("Test Medium · two pulses") { model.testWarning(.medium) }
                    Button("Test High · urgent pulses + voice") { model.testWarning(.high) }
                    Button("Stop test") { model.endWarningTest() }
                    Text("Tests play audio and vibration even if Voice or Touch is off. Live alerts resume after two seconds.").font(.caption)
                    if !model.hapticTestMessage.isEmpty { Text(model.hapticTestMessage).font(.caption) }
                }
                Section {
                    Text(model.status).font(.caption)
                    Text("ARKit detection cannot continue behind other iPhone apps. Returning to SafeStep resumes an enabled walk and remeasures the floor.").font(.caption)
                    Text("No hazard alerts until the floor is calibrated. Floor-level points are excluded from obstacles. Stairs and drops remain prototype estimates.").font(.caption)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.stepBackground)
            .foregroundStyle(Color.stepInk)
            .navigationTitle("Sensor details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.light).tint(.stepAccent)
        .onDisappear { model.endWarningTest() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).monospacedDigit().foregroundStyle(.secondary) }
    }
}
