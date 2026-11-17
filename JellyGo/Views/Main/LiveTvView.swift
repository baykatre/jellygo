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
    @State private var heroIndex = 0

    @ObservedObject private var externalStore = ExternalLiveTvStore.shared

    private var filteredChannels: [JellyfinItem] {
        var list = vm.channels.filter(vm.matchesFilters)

        if showFavoritesOnly {
            list = list.filter { $0.userData?.isFavorite == true }
        }

        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter { ch in
                ch.name.lowercased().contains(q)
                || ch.channelNumber?.lowercased().contains(q) == true
                || ch.currentProgram?.name.lowercased().contains(q) == true
                || (vm.isExternal(ch) && externalStore.groupName(forItemId: ch.id)?.lowercased().contains(q) == true)
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

    /// Favorites if any, else the first few channels — featured in the hero slider.
    private var heroChannels: [JellyfinItem] {
        let pool = vm.channels.filter(vm.matchesFilters)
        let favorites = pool.filter { $0.userData?.isFavorite == true }
        return Array((favorites.isEmpty ? pool : favorites).prefix(8))
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
                        if externalStore.playlists.isEmpty && externalStore.showJellyfinChannels {
                            Text(String(localized: "No live TV channels found on this server.", bundle: AppState.currentBundle))
                        } else {
                            Text(String(localized: "No channels to show. Check the sources in Live TV Settings.", bundle: AppState.currentBundle))
                        }
                    } actions: {
                        Button(String(localized: "Retry", bundle: AppState.currentBundle)) {
                            Task { await vm.reloadJellyfin() }
                        }
                    }
                } else {
                    liveContent
                }
            }
            .safeAreaInset(edge: .top) { liveTvHeader }
            .navigationBarHidden(true)
            // The server's channel list is not fixed for the life of the app: ask again
            // when the screen comes back (throttled inside the view model).
            .onAppear { Task { await vm.refreshJellyfinIfStale() } }
        }
        .fullScreenCover(isPresented: $isFullscreen, onDismiss: {
            AppDelegate.orientationLock = .portrait
            PlayerContainerView.rotate(to: .portrait)
            if let playingItem = playerVM.item {
                // Sync channel if changed in fullscreen (user browsed channels while playing)
                if playingItem.id != currentChannel?.id,
                   let ch = vm.channels.first(where: { $0.id == playingItem.id }) {
                    currentChannel = ch
                }
            } else {
                // Player was fully stopped (closed via X) — nothing is playing anymore
                currentChannel = nil
            }
        }) {
            if let ch = currentChannel {
                JellyGoPlayerView(item: ch, vm: playerVM, externalVM: true)
                    .environmentObject(appState)
            }
        }
    }

    // MARK: - Header

    private var liveTvHeader: some View {
        HStack {
            Text(String(localized: "Live TV", bundle: AppState.currentBundle))
                .font(.largeTitle.bold())

            Spacer()

            HStack(spacing: 8) {
                Button {
                    withAnimation(.spring(duration: 0.3)) { isSearchVisible.toggle() }
                    if !isSearchVisible { searchText = "" }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isSearchVisible ? Color.accentColor : .primary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Button {
                    withAnimation(.spring(duration: 0.3)) { showFavoritesOnly.toggle() }
                    UserDefaults.standard.set(showFavoritesOnly, forKey: "jellygo.liveTvFavoritesOnly")
                } label: {
                    Image(systemName: showFavoritesOnly ? "heart.fill" : "heart")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(showFavoritesOnly ? JGColor.brand : .primary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
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

            // Always on screen when there are channels: it is also the legend that says
            // which kind of channels (server / external list) are being shown.
            if !vm.availableSources.isEmpty {
                sourceFilterBar
            }

            ScrollView {
                VStack(spacing: 14) {
                    if searchText.isEmpty && !showFavoritesOnly, !heroChannels.isEmpty {
                        liveHeroSlider
                    }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                              spacing: 12) {
                        ForEach(filteredChannels) { channel in
                            Button {
                                selectChannel(channel)
                            } label: {
                                LiveChannelTile(
                                    channel: channel,
                                    serverURL: vm.serverURL,
                                    isPlaying: channel.id == currentChannel?.id,
                                    sourceBadge: vm.showsSourceBadges
                                        ? LiveChannelTile.SourceBadge(isExternal: vm.isExternal(channel), title: vm.sourceLabel(for: channel))
                                        : nil
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    toggleFavorite(channel)
                                } label: {
                                    if channel.userData?.isFavorite == true {
                                        Label(String(localized: "Remove from Favorites", bundle: AppState.currentBundle), systemImage: "heart.slash")
                                    } else {
                                        Label(String(localized: "Add to Favorites", bundle: AppState.currentBundle), systemImage: "heart")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 24)
            }
            .brandPage()
            .animation(.default, value: filteredChannels.map(\.id))
        }
    }

    // MARK: - Hero Slider

    private var liveHeroSlider: some View {
        VStack(spacing: 8) {
            TabView(selection: $heroIndex) {
                ForEach(Array(heroChannels.enumerated()), id: \.element.id) { index, channel in
                    liveHeroCard(channel: channel)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 168)
            .onAppear { if heroIndex >= heroChannels.count { heroIndex = 0 } }

            if heroChannels.count > 1 {
                HStack(spacing: 5) {
                    ForEach(heroChannels.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == heroIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: i == heroIndex ? 16 : 5, height: 5)
                    }
                }
                .animation(.spring(duration: 0.3), value: heroIndex)
            }
        }
        .padding(.bottom, 4)
    }

    private func heroColor(for channel: JellyfinItem) -> Color {
        Color(hue: Double(abs(channel.name.hashValue % 360)) / 360.0, saturation: 0.55, brightness: 0.32)
    }

    private func liveHeroCard(channel: JellyfinItem) -> some View {
        Button { selectChannel(channel) } label: {
            ZStack {
                LinearGradient(
                    colors: [heroColor(for: channel), heroColor(for: channel).opacity(0.6)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )

                FallbackAsyncImage(
                    primaryURL: LiveTvChannelArt.logoURL(for: channel, serverURL: vm.serverURL, maxWidth: 400),
                    fallbackURL: nil,
                    placeholder: Color.clear,
                    contentMode: .fit
                )
                .padding(28)
                .opacity(0.85)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

                LinearGradient(
                    colors: [.black.opacity(0.7), .clear],
                    startPoint: .bottom, endPoint: .top
                )
                .frame(maxHeight: .infinity, alignment: .bottom)

                VStack(alignment: .leading, spacing: 6) {
                    Spacer(minLength: 0)

                    HStack(spacing: 6) {
                        Circle().fill(JGColor.brand).frame(width: 7, height: 7)
                            .shadow(color: JGColor.brand.opacity(0.8), radius: 3)
                        Text(String(localized: "LIVE", bundle: AppState.currentBundle))
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                        if let num = channel.channelNumber {
                            Text("\u{00B7} \(num)")
                                .font(.system(size: 11, weight: .bold).monospacedDigit())
                                .opacity(0.7)
                        }
                    }
                    .foregroundStyle(.white)

                    Text(channel.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if let program = channel.currentProgram {
                        Text(program.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(String(localized: "Watch Live", bundle: AppState.currentBundle))
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.white, in: Capsule())
                    .padding(.top, 4)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
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
            await vm.setFavorite(channel, !current)
        }
    }

    // MARK: - Source / group filter

    private var sourceFilterBar: some View {
        VStack(spacing: 6) {
            filterChipRow {
                if vm.availableSources.count > 1 {
                    filterChip(String(localized: "All", bundle: AppState.currentBundle),
                               count: vm.channelCount(for: .all), selected: vm.sourceFilter == .all) {
                        vm.sourceFilter = .all
                    }
                }
                ForEach(vm.availableSources) { source in
                    // With a single source the chip is just a label for the channel type.
                    filterChip(source.title, icon: source.icon, count: vm.channelCount(for: source.filter),
                               selected: vm.availableSources.count > 1 && vm.sourceFilter == source.filter) {
                        if vm.availableSources.count > 1 { vm.sourceFilter = source.filter }
                    }
                }
            }
            if !vm.availableGroups.isEmpty {
                filterChipRow {
                    filterChip(String(localized: "All Groups", bundle: AppState.currentBundle), selected: vm.groupFilter == nil, small: true) {
                        vm.groupFilter = nil
                    }
                    ForEach(vm.availableGroups, id: \.self) { group in
                        filterChip(group, selected: vm.groupFilter == group, small: true) {
                            vm.groupFilter = group
                        }
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func filterChipRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content() }
                .padding(.horizontal, 16)
        }
    }

    private func filterChip(_ title: String, icon: String? = nil, count: Int? = nil, selected: Bool,
                            small: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(duration: 0.3)) { action() }
        } label: {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 10, weight: .bold))
                }
                Text(title)
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .opacity(0.6)
                }
            }
                .font(.system(size: small ? 12 : 13, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, small ? 10 : 12)
                .padding(.vertical, small ? 5 : 7)
                .background(selected ? JGColor.brand : Color.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(selected ? 0 : 0.10), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Live Channel Row (Flat List)

private struct LiveChannelTile: View {
    struct SourceBadge {
        let isExternal: Bool
        let title: String
    }

    let channel: JellyfinItem
    let serverURL: String
    let isPlaying: Bool
    var sourceBadge: SourceBadge?

    private var isFavorite: Bool { channel.userData?.isFavorite == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Channel logo
            FallbackAsyncImage(
                primaryURL: LiveTvChannelArt.logoURL(for: channel, serverURL: serverURL, maxWidth: 240),
                fallbackURL: nil,
                placeholder: Text(channel.name.prefix(2).uppercased())
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary),
                contentMode: .fit
            )
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .padding(.vertical, 4)

            HStack(spacing: 6) {
                if let num = channel.channelNumber {
                    Text(num)
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(channel.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isPlaying {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tint)
                }
            }

            Text(channel.currentProgram?.name ?? String(localized: "No program info", bundle: AppState.currentBundle))
                .font(.system(size: 13))
                .foregroundStyle(channel.currentProgram == nil ? .tertiary : .secondary)
                .lineLimit(1)

            GeometryReader { geo in
                Capsule()
                    .fill(.white.opacity(0.16))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.tint)
                            .frame(width: geo.size.width * (channel.currentProgram?.progress ?? 0))
                    }
            }
            .frame(height: 3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(highlighted: isPlaying)
        .overlay(alignment: .topTrailing) {
            if isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(JGColor.danger)
                    .padding(10)
            }
        }
        .overlay(alignment: .topLeading) {
            if let sourceBadge {
                // Small mark for where the channel comes from (server or an external list).
                HStack(spacing: 3) {
                    Image(systemName: sourceBadge.isExternal ? "list.bullet.rectangle" : "server.rack")
                        .font(.system(size: 8, weight: .bold))
                    // `frame(maxWidth:)` alone stretched every badge to the full 70 pt, leaving a gap
                    // after short names; fixedSize makes it hug the text and only cap long ones.
                    Text(sourceBadge.title)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: 70, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.08), in: Capsule())
                .padding(8)
            }
        }
    }
}
