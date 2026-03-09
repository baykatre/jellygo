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
        .onChange(of: networkMonitor.isConnected) { _, connected in
            if connected && appState.isAuthenticated {
                Task {
                    await LocalPlaybackStore.syncPendingPositions(
                        serverURL: appState.serverURL, token: appState.token
                    )
                }
            }
        }
        .task {
            // Sync any pending positions on launch if online
            if networkMonitor.isConnected && appState.isAuthenticated {
                await LocalPlaybackStore.syncPendingPositions(
                    serverURL: appState.serverURL, token: appState.token
                )
                // Cache user avatar for offline display
                DownloadManager.shared.downloadUserAvatar(
                    userId: appState.userId,
                    serverURL: appState.serverURL,
                    token: appState.token
                )
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
