import SwiftUI

struct LiveTvView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var vm: LiveTvViewModel
    @ObservedObject var playerVM: PlayerViewModel

    @State private var scrollPositionId: String?
    @State private var currentChannel: JellyfinItem?
    @State private var isFullscreen = false
    @State private var inlineRefreshId = 0
    @State private var showFavoritesOnly: Bool = UserDefaults.standard.bool(forKey: "jellygo.liveTvFavoritesOnly")
    @State private var channelSwitchTask: Task<Void, Never>?
    @State private var searchText = ""
    @State private var isSearchVisible = false

    private var filteredChannels: [JellyfinItem] {
        var list = vm.channels

        if showFavoritesOnly {
            list = list.filter { $0.userData?.isFavorite == true }
        }

        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter { ch in
                ch.name.lowercased().contains(q)
                || ch.channelNumber?.lowercased().contains(q) == true
                || ch.currentProgram?.name.lowercased().contains(q) == true
            }
        }

        // Favorites first
        if !showFavoritesOnly {
            list.sort { a, b in
                let aFav = a.userData?.isFavorite == true
                let bFav = b.userData?.isFavorite == true
                if aFav != bFav { return aFav }
                return false
            }
        }

        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.channels.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = vm.error, vm.channels.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "Live TV", bundle: AppState.currentBundle), systemImage: "tv")
                    } description: {
                        Text(error)
                    } actions: {
                        Button(String(localized: "Retry", bundle: AppState.currentBundle)) {
                            Task { await vm.load(appState: appState) }
                        }
                    }
                } else if vm.channels.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "No Channels", bundle: AppState.currentBundle), systemImage: "tv.slash")
                    } description: {
                        Text(String(localized: "No live TV channels found on this server.", bundle: AppState.currentBundle))
                    }
                } else {
                    liveContent
                }
            }
            .navigationTitle(String(localized: "Live TV", bundle: AppState.currentBundle))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        Button {
                            withAnimation(.spring(duration: 0.3)) { isSearchVisible.toggle() }
                            if !isSearchVisible { searchText = "" }
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(isSearchVisible ? .primary : .secondary)
                        }
                        Button {
                            withAnimation(.spring(duration: 0.3)) { showFavoritesOnly.toggle() }
                            UserDefaults.standard.set(showFavoritesOnly, forKey: "jellygo.liveTvFavoritesOnly")
                        } label: {
                            Image(systemName: showFavoritesOnly ? "heart.fill" : "heart")
                                .foregroundStyle(showFavoritesOnly ? .red : .secondary)
                        }
                    }
                }
            }
        }
        .onChange(of: vm.channels) { _, channels in
            guard !channels.isEmpty, currentChannel == nil else { return }
            autoSelectInitialChannel(from: channels)
        }
        .onAppear {
            if !vm.channels.isEmpty && currentChannel == nil {
                autoSelectInitialChannel(from: vm.channels)
            }
        }
        .fullScreenCover(isPresented: $isFullscreen, onDismiss: {
            AppDelegate.orientationLock = .portrait
            PlayerContainerView.rotate(to: .portrait)
            // Sync channel if changed in fullscreen
            if let playingItem = playerVM.item,
               playingItem.id != currentChannel?.id,
               let ch = vm.channels.first(where: { $0.id == playingItem.id }) {
                currentChannel = ch
                withAnimation(.spring(duration: 0.3)) {
                    scrollPositionId = ch.id
                }
            }
            inlineRefreshId += 1
        }) {
            if let ch = currentChannel {
                FullscreenLivePlayerWrapper(item: ch, vm: playerVM)
                    .environmentObject(appState)
            }
        }
    }

    // MARK: - Main Content

    private var liveContent: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Inline player — same JellyGoPlayerView
                if let ch = currentChannel {
                    JellyGoPlayerView(item: ch, vm: playerVM, externalVM: true,
                                      isInline: true, onFullscreen: { goFullscreen() })
                        .frame(height: geo.size.height * 0.45)
                        .clipped()
                        .clipShape(Rectangle())
                        .id("\(ch.id)-\(inlineRefreshId)")
                }

                // Channel strip
                channelStrip(geo: geo)
            }
        }
    }

    // MARK: - Channel Strip

    private func channelStrip(geo: GeometryProxy) -> some View {
        let channels = filteredChannels

        return VStack(spacing: 0) {
            if isSearchVisible {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                    TextField(String(localized: "Search channels", bundle: AppState.currentBundle), text: $searchText)
                        .font(.system(size: 14))
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 14))
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Horizontal scrollable channel cards
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(channels) { channel in
                        LiveChannelCard(
                            channel: channel,
                            serverURL: vm.serverURL,
                            isSelected: channel.id == currentChannel?.id,
                            onToggleFavorite: { toggleFavorite(channel) }
                        )
                        .id(channel.id)
                        .containerRelativeFrame(.horizontal, count: 3, spacing: 12)
                        .onTapGesture {
                            switchToChannel(channel)
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 20)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrollPositionId)
            .contentMargins(.horizontal, 0, for: .scrollIndicators)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    private func autoSelectInitialChannel(from channels: [JellyfinItem]) {
        let sorted = filteredChannels
        guard !sorted.isEmpty else { return }

        let initial = sorted.first(where: { $0.userData?.isFavorite == true }) ?? sorted[0]
        scrollPositionId = initial.id
        switchToChannel(initial)
    }

    private func switchToChannel(_ channel: JellyfinItem) {
        guard channel.id != currentChannel?.id else { return }
        channelSwitchTask?.cancel()
        currentChannel = channel
        withAnimation(.spring(duration: 0.3)) {
            scrollPositionId = channel.id
        }
        startPlaying(channel)
    }

    private func goFullscreen() {
        print("[LIVETV] goFullscreen called, setting isFullscreen=true")
        AppDelegate.orientationLock = .landscape
        PlayerContainerView.rotate(to: .landscapeRight)
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            isFullscreen = true
            print("[LIVETV] isFullscreen set to true")
        }
    }

    private func startPlaying(_ channel: JellyfinItem) {
        playerVM.stop()
        Task {
            await playerVM.load(item: channel, appState: appState)
        }
    }

    private func toggleFavorite(_ channel: JellyfinItem) {
        let current = channel.userData?.isFavorite == true
        Task {
            try? await JellyfinAPI.shared.setFavorite(
                serverURL: appState.serverURL,
                itemId: channel.id,
                userId: appState.userId,
                token: appState.token,
                isFavorite: !current
            )
            if let idx = vm.channels.firstIndex(where: { $0.id == channel.id }) {
                var updated = vm.channels[idx]
                var ud = updated.userData ?? JellyfinUserData(playbackPositionTicks: nil, played: nil, isFavorite: nil, playCount: nil)
                ud.isFavorite = !current
                updated.userData = ud
                withAnimation(.spring(duration: 0.3)) {
                    vm.channels[idx] = updated
                }
            }
        }
    }
}

// MARK: - Live Channel Card (Horizontal Strip)

// Wrapper to dismiss fullscreen via @Environment
private struct FullscreenLivePlayerWrapper: View {
    let item: JellyfinItem
    @ObservedObject var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        JellyGoPlayerView(item: item, vm: vm, externalVM: true, onFullscreen: { [dismiss] in
            print("[LIVETV] fullscreen wrapper dismiss called")
            dismiss()
        })
    }
}

private struct LiveChannelCard: View {
    let channel: JellyfinItem
    let serverURL: String
    let isSelected: Bool
    var onToggleFavorite: () -> Void

    private var isFavorite: Bool { channel.userData?.isFavorite == true }

    var body: some View {
        VStack(spacing: 0) {
            // Channel logo
            ZStack {
                LinearGradient(
                    colors: [
                        Color(hue: Double(abs(channel.name.hashValue % 360)) / 360.0, saturation: 0.3, brightness: 0.15),
                        Color(hue: Double(abs(channel.name.hashValue % 360)) / 360.0, saturation: 0.4, brightness: 0.08)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )

                AsyncImage(url: JellyfinAPI.shared.imageURL(serverURL: serverURL, itemId: channel.id, imageType: "Primary", maxWidth: 200)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fit)
                            .padding(10)
                    default:
                        Text(channel.name.prefix(2).uppercased())
                            .font(.system(size: 20, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.15))
                    }
                }
            }
            .frame(height: 70)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 12))

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let num = channel.channelNumber {
                        Text(num)
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(channel.name)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.red)
                    }
                }

                if let program = channel.currentProgram {
                    Text(program.name)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let progress = program.progress {
                        GeometryReader { geo in
                            Capsule()
                                .fill(.quaternary)
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                        .frame(width: geo.size.width * progress)
                                }
                        }
                        .frame(height: 2)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .scaleEffect(isSelected ? 1.0 : 0.92)
        .opacity(isSelected ? 1.0 : 0.7)
        .animation(.spring(duration: 0.3), value: isSelected)
        .contextMenu {
            Button {
                onToggleFavorite()
            } label: {
                if isFavorite {
                    Label(String(localized: "Remove from Favorites", bundle: AppState.currentBundle), systemImage: "heart.slash")
                } else {
                    Label(String(localized: "Add to Favorites", bundle: AppState.currentBundle), systemImage: "heart")
                }
            }
        }
    }
}
