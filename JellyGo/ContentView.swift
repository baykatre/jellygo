//
//  ContentView.swift
//  JellyGo
//
//  Created by Anıl Öztürk on 8.03.2026.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var networkMonitor: NetworkMonitor

    var body: some View {
        Group {
            if appState.isAuthenticated {
                if networkMonitor.isConnected {
                    HomeView()
                } else {
                    OfflineView()
                }
            } else {
                ServerView()
            }
        }
        .animation(.easeInOut(duration: 0.4), value: appState.isAuthenticated)
        .animation(.easeInOut(duration: 0.4), value: networkMonitor.isConnected)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
