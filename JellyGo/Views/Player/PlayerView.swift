import SwiftUI
import AVKit

// MARK: - PlayerView

struct PlayerView: View {
    let item: JellyfinItem
    var localURL: URL? = nil

    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = PlayerViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showQualityPicker = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if vm.isLoading {
                loadingView
            } else if let error = vm.error {
                errorView(message: error)
            } else if let player = vm.player {
                NativePlayerView(
                    player: player,
                    selectedQuality: vm.selectedQuality,
                    showQualityButton: localURL == nil,
                    onQualityTap: { showQualityPicker = true }
                ) {
                    dismiss()
                }
                .ignoresSafeArea()
            }
        }
        .statusBarHidden(true)
        .task {
            if let url = localURL {
                await vm.loadLocal(url: url, item: item, appState: appState)
            } else {
                await vm.load(item: item, appState: appState)
            }
        }
        .onDisappear { vm.stop() }
        .confirmationDialog("Quality", isPresented: $showQualityPicker, titleVisibility: .visible) {
            ForEach(VideoQuality.allCases) { quality in
                Button {
                    Task { await vm.changeQuality(to: quality) }
                } label: {
                    HStack {
                        Text(quality.rawValue)
                        if vm.selectedQuality == quality { Text("✓") }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
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
            Button("Dismiss") { dismiss() }
                .buttonStyle(.bordered)
                .tint(.white)
        }
    }
}

// MARK: - Native AVPlayerViewController

struct NativePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let selectedQuality: VideoQuality
    var showQualityButton: Bool = true
    var onQualityTap: () -> Void
    var onDone: () -> Void

    private static let qualityButtonTag = 8001

    func makeCoordinator() -> Coordinator {
        Coordinator(onDone: onDone, onQualityTap: onQualityTap)
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

        DispatchQueue.main.async {
            AppDelegate.orientationLock = .allButUpsideDown
            PlayerView.rotate(to: .landscapeRight)
        }

        if showQualityButton, let overlay = vc.contentOverlayView {
            var config = UIButton.Configuration.plain()
            config.title = selectedQuality.rawValue
            config.baseForegroundColor = .white
            config.background.backgroundColor = UIColor.white.withAlphaComponent(0.18)
            config.background.cornerRadius = 8
            config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs; a.font = .systemFont(ofSize: 13, weight: .semibold); return a
            }
            let btn = UIButton(configuration: config)
            btn.tag = Self.qualityButtonTag
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.addTarget(context.coordinator, action: #selector(Coordinator.qualityTapped), for: .touchUpInside)
            overlay.addSubview(btn)
            NSLayoutConstraint.activate([
                btn.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 12),
                btn.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -16)
            ])
        }

        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        context.coordinator.onQualityTap = onQualityTap
        if let btn = vc.contentOverlayView?.viewWithTag(Self.qualityButtonTag) as? UIButton,
           var config = btn.configuration {
            config.title = selectedQuality.rawValue
            btn.configuration = config
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var onDone: () -> Void
        var onQualityTap: () -> Void

        init(onDone: @escaping () -> Void, onQualityTap: @escaping () -> Void) {
            self.onDone = onDone
            self.onQualityTap = onQualityTap
        }

        @objc func qualityTapped() { onQualityTap() }

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
