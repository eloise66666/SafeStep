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
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Spacer()
                // Frame the original artwork's transparent margins without modifying the asset.
                Image("BrandLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .offset(y: -12)
                    .frame(width: 140, height: 112)
                    .clipped()
                    .background(Color.stepLogoSurface, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.stepSage.opacity(0.45), lineWidth: 1))
                    .accessibilityLabel("SafeStep logo")
                Text("SafeStep").font(.largeTitle.bold())
                Text("A heads-up for what’s ahead.")
                    .font(.title2).foregroundStyle(Color.stepAccent)
                Text("Stand still on flat ground. Tilt the camera \(DetectionConfiguration.standard.calibrationPitchText) downward and hold it steady while SafeStep measures the floor.")
                    .foregroundStyle(.secondary)
                Spacer()
                NavigationLink { LiveDetectionView() } label: {
                    HStack { Text("Start scanning"); Spacer(); Image(systemName: "arrow.right") }
                        .font(.headline).padding(20).foregroundStyle(Color.stepBackground)
                        .background(Color.stepAccent, in: RoundedRectangle(cornerRadius: 18))
                }
                .disabled(!WalkSession.supportsLiDAR)
                .opacity(WalkSession.supportsLiDAR ? 1 : 0.45)
                Text(WalkSession.supportsLiDAR ? "Keep SafeStep visible while scanning. Keep looking ahead; this prototype can miss hazards." : "Live scanning requires a LiDAR-equipped iPhone or iPad.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .foregroundStyle(Color.stepInk)
            .background(Color.stepBackground)
            .preferredColorScheme(.light)
        }
        .tint(.stepAccent)
    }
}

#Preview { StartView() }
