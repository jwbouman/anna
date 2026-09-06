import SwiftUI

struct KoersKompasLaunchView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemBackground), Color.blue.opacity(0.12), Color.teal.opacity(0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.blue)
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 6) {
                    Text("KoersKompas")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))

                    Text("Technische analyse")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(32)
        }
    }
}

#Preview {
    KoersKompasLaunchView()
}
