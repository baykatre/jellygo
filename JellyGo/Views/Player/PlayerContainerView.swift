import SwiftUI

/// Single entry point for playback — always uses JellyGoPlayerView.
struct PlayerContainerView: View {
    let item: JellyfinItem
    var localURL: URL? = nil
    var qualityOverride: VideoQuality? = nil
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = PlayerViewModel()

    var body: some View {
        JellyGoPlayerView(item: item, localURL: localURL, qualityOverride: qualityOverride, vm: vm)
            .environmentObject(appState)
    }

    /// Requests a device orientation change.
    static func rotate(to orientation: UIInterfaceOrientation) {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        let mask: UIInterfaceOrientationMask = orientation == .portrait ? .portrait : .landscapeRight
        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        windowScene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
