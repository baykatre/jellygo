import SwiftUI

/// Routes playback to the correct player based on AppState.playerEngine.
/// Use this everywhere instead of manually checking the engine.
struct PlayerContainerView: View {
    let item: JellyfinItem
    var localURL: URL? = nil
    @EnvironmentObject private var appState: AppState

    var body: some View {
        switch appState.playerEngine {
        case .native:
            PlayerView(item: item, localURL: localURL)
                .environmentObject(appState)
        case .vlc:
            VLCPlayerView(item: item, localURL: localURL)
                .environmentObject(appState)
        }
    }
}
