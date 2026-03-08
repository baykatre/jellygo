import SwiftUI
import AVKit

// MARK: - PlayerView

struct PlayerView: View {
    let item: JellyfinItem

    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = PlayerViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if vm.isLoading {
                loadingView
            } else if let error = vm.error {
                errorView(message: error)
            } else if let player = vm.player {
                NativePlayerView(player: player) {
                    dismiss()
                }
                .ignoresSafeArea()
            }
        }
        .statusBarHidden(true)
        .task {
            await vm.load(item: item, appState: appState)
        }
        .onDisappear {
            vm.stop()
        }
    }

    static func rotate(to orientation: UIInterfaceOrientation) {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        let mask: UIInterfaceOrientationMask = orientation == .portrait ? .portrait : .landscapeRight
        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        windowScene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.4)
            Text(item.name)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Geri Dön") { dismiss() }
                .buttonStyle(.bordered)
                .tint(.white)
        }
    }
}

// MARK: - Native AVPlayerViewController

struct NativePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    var onDone: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDone: onDone)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.updatesNowPlayingInfoCenter = true
        vc.entersFullScreenWhenPlaybackBegins = true
        vc.exitsFullScreenWhenPlaybackEnds = false
        vc.delegate = context.coordinator

        // Force landscape as soon as the VC is created
        DispatchQueue.main.async {
            AppDelegate.orientationLock = .allButUpsideDown
            PlayerView.rotate(to: .landscapeRight)
        }

        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    // MARK: - Coordinator / Delegate

    class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }

        // User tapped "Done" to exit fullscreen
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.onDone()
            }
        }
    }
}
