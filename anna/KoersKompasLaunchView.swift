import SwiftUI

struct KoersKompasLaunchView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.98, blue: 1.0),
                    Color(red: 0.89, green: 0.95, blue: 1.0),
                    Color(red: 0.88, green: 0.97, blue: 0.96)
                ],
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
