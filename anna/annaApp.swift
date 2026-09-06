//
//  annaApp.swift
//  anna
//
//  Created by Jan Bouman on 11/08/2026.
//

import SwiftUI

@main
struct annaApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @State private var showingLaunchView = true

    var body: some View {
        ZStack {
            ContentView()

            if showingLaunchView {
                KoersKompasLaunchView()
                    .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(1.1))

            withAnimation(.easeOut(duration: 0.35)) {
                showingLaunchView = false
            }
        }
    }
}
