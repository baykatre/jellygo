//
//  JellyGoApp.swift
//  JellyGo
//
//  Created by Anıl Öztürk on 8.03.2026.
//

import SwiftUI

@main
struct JellyGoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(appState)
                    .environmentObject(DownloadManager.shared)
                    .environmentObject(NetworkMonitor.shared)
                    .environment(\.locale, appState.currentLocale)

                if showSplash {
                    SplashScreen()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .preferredColorScheme(
                appState.appTheme == "dark" ? .dark :
                appState.appTheme == "light" ? .light : nil
            )
            .task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 0.4)) { showSplash = false }
            }
        }
    }
}

struct SplashScreen: View {
    @State private var scale: CGFloat = 0.8
    @State private var opacity: Double = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color.black : Color.white).ignoresSafeArea()
            VStack(spacing: 20) {
                Image("SplashIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140, height: 140)
                    .mask(RoundedRectangle(cornerRadius: 32, style: .continuous).padding(3))
                    .shadow(color: colorScheme == .dark ? .white.opacity(0.06) : .black.opacity(0.1), radius: 20)
                    .shadow(color: .accentColor.opacity(0.2), radius: 40)
                    .scaleEffect(scale)
            }
            .opacity(opacity)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                scale = 1.0
                opacity = 1.0
            }
        }
    }
}
