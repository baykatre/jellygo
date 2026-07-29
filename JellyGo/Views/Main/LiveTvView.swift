import SwiftUI

struct LiveTvView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var vm: LiveTvViewModel
    @ObservedObject var playerVM: PlayerViewModel

    @State private var currentChannel: JellyfinItem?
    @State private var isFullscreen = false
    @State private var showFavoritesOnly: Bool = UserDefaults.standard.bool(forKey: "jellygo.liveTvFavoritesOnly")
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
        .fullScreenCover(isPresented: $isFullscreen, onDismiss: {
            AppDelegate.orientationLock = .portrait
            PlayerContainerView.rotate(to: .portrait)
            // Sync channel if changed in fullscreen (user browsed channels while playing)
            if let playingItem = playerVM.item,
               playingItem.id != currentChannel?.id,
               let ch = vm.channels.first(where: { $0.id == playingItem.id }) {
                currentChannel = ch
            }
        }) {
            if let ch = currentChannel {
                FullscreenLivePlayerWrapper(item: ch, vm: playerVM)
                    .environmentObject(appState)
            }
        }
    }

    // MARK: - Main Content

    private var liveContent: some View {
        VStack(spacing: 0) {
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
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            List {
                ForEach(filteredChannels) { channel in
                    Button {
                        selectChannel(channel)
                    } label: {
                        LiveChannelRow(
                            channel: channel,
                            serverURL: vm.serverURL,
                            isPlaying: channel.id == currentChannel?.id
                        )
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button {
                            toggleFavorite(channel)
                        } label: {
                            if channel.userData?.isFavorite == true {
                                Label(String(localized: "Remove from Favorites", bundle: AppState.currentBundle), systemImage: "heart.slash")
                            } else {
                                Label(String(localized: "Add to Favorites", bundle: AppState.currentBundle), systemImage: "heart")
                            }
                        }
                        .tint(.red)
                    }
                }
            }
            .listStyle(.plain)
            .animation(.default, value: filteredChannels.map(\.id))
        }
    }

    // MARK: - Actions

    private func selectChannel(_ channel: JellyfinItem) {
        currentChannel = channel
        if playerVM.item?.id != channel.id {
            startPlaying(channel)
        }
        goFullscreen()
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

// MARK: - Fullscreen Player Wrapper

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

// MARK: - Live Channel Row (Flat List)

private struct LiveChannelRow: View {
    let channel: JellyfinItem
    let serverURL: String
    let isPlaying: Bool

    private var isFavorite: Bool { channel.userData?.isFavorite == true }

    var body: some View {
        HStack(spacing: 12) {
            // Channel logo
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)

                AsyncImage(url: JellyfinAPI.shared.imageURL(serverURL: serverURL, itemId: channel.id, imageType: "Primary", maxWidth: 120)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fit)
                            .padding(6)
                    default:
                        Text(channel.name.prefix(2).uppercased())
                            .font(.system(size: 14, weight: .black, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let num = channel.channelNumber {
                        Text(num)
                            .font(.system(size: 12, weight: .bold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(channel.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if isPlaying {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.tint)
                    }
                }

                if let program = channel.currentProgram {
                    Text(program.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let progress = program.progress {
                        GeometryReader { geo in
                            Capsule()
                                .fill(.quaternary)
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(.tint)
                                        .frame(width: geo.size.width * progress)
                                }
                        }
                        .frame(height: 3)
                    }
                } else {
                    Text(String(localized: "No program info", bundle: AppState.currentBundle))
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            if isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
