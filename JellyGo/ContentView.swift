//
//  ContentView.swift
//  JellyGo
//
//  Created by Anıl Öztürk on 8.03.2026.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.isAuthenticated {
                HomeView()
            } else {
                ServerView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.isAuthenticated)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
