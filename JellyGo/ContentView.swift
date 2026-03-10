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
    @State private var retryTask: Task<Void, Never>?

    private var showOffline: Bool {
        !networkMonitor.isConnected || appState.serverUnreachable || appState.manualOffline
    }

    /// Skip connectivity checks while player is active or manual offline
    private var shouldSkipChecks: Bool {
        appState.isPlayerActive || appState.manualOffline
    }

    var body: some View {
        Group {
            if appState.isAuthenticated {
                if showOffline {
                    OfflineView()
                } else {
                    HomeView()
                }
            } else {
                ServerView()
            }
        }
        .animation(.easeInOut(duration: 0.4), value: appState.isAuthenticated)
        .animation(.easeInOut(duration: 0.4), value: showOffline)
        .onChange(of: networkMonitor.isConnected) { _, connected in
            guard !shouldSkipChecks else { return }
            if connected && appState.isAuthenticated {
                Task {
                    await appState.validateAndFallback()
                    if !appState.serverUnreachable {
                        stopRetry()
                        await LocalPlaybackStore.syncPendingPositions(
                            serverURL: appState.serverURL, token: appState.token
                        )
                    }
                }
            } else if !connected {
                appState.serverUnreachable = false
            }
        }
        .onChange(of: networkMonitor.isWiFi) { _, _ in
            guard !shouldSkipChecks else { return }
            if networkMonitor.isConnected && appState.isAuthenticated {
                Task { await appState.validateAndFallback() }
            }
        }
        .onChange(of: appState.serverUnreachable) { _, unreachable in
            if unreachable && !shouldSkipChecks {
                startRetry()
            } else {
                stopRetry()
            }
        }
        .onChange(of: appState.manualOffline) { _, manual in
            if manual {
                stopRetry()
            } else if networkMonitor.isConnected && appState.isAuthenticated {
                Task { await appState.validateAndFallback() }
            }
        }
        .onChange(of: appState.isPlayerActive) { _, active in
            if active {
                stopRetry()
            } else if appState.serverUnreachable && !appState.manualOffline {
                // Player kapandı, hâlâ unreachable → retry başlat
                startRetry()
            }
        }
        .task {
            guard networkMonitor.isConnected && appState.isAuthenticated && !shouldSkipChecks else { return }
            await appState.validateAndFallback()
            if !appState.serverUnreachable {
                await LocalPlaybackStore.syncPendingPositions(
                    serverURL: appState.serverURL, token: appState.token
                )
                DownloadManager.shared.downloadUserAvatar(
                    userId: appState.userId,
                    serverURL: appState.serverURL,
                    token: appState.token
                )
            }
        }
    }

    // MARK: - Periodic Retry (only while serverUnreachable, NOT during playback)

    private func startRetry() {
        stopRetry()
        retryTask = Task {
            var interval: UInt64 = 10
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, appState.serverUnreachable,
                      !appState.manualOffline, !appState.isPlayerActive else { break }
                await appState.validateAndFallback()
                interval = min(interval * 2, 60)  // exponential backoff: 10 → 20 → 40 → 60 cap
            }
        }
    }

    private func stopRetry() {
        retryTask?.cancel()
        retryTask = nil
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
