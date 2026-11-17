import SwiftUI

/// Settings pages that live on the Home stack's *path*. They must be value-based: a page
/// pushed with `isPresented`/destination links stays on top of later path pushes, so item
/// links opened from Downloads would land underneath it.
enum SettingsRoute: Hashable {
    case settings, downloadSettings, downloads
}

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dm: DownloadManager
    @StateObject private var vm = HomeViewModel()
    @StateObject private var exploreVM = ExploreViewModel()
    @StateObject private var liveTvVM = LiveTvViewModel()
    @StateObject private var liveTvPlayerVM = PlayerViewModel()
    @State private var heroPlayItem: JellyfinItem?
    @State private var autoPlayItem: JellyfinItem?
    @State private var downloadBanner: PausedDownload?
    @State private var bannerTask: Task<Void, Never>?
    @State private var selectedTab: Int = 0
    @State private var homePath = NavigationPath()
    @State private var heroPullDown: CGFloat = 0
    @State private var heroScrollOffset: CGFloat = 0
    @State private var showOverlay = true
    @State private var badgeBounce = false

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(String(localized: "Home", bundle: AppState.currentBundle), systemImage: "house.fill", value: 0) {
                mainTab
            }

            Tab(String(localized: "Explore", bundle: AppState.currentBundle), systemImage: "safari.fill", value: 1) {
                ExploreView(vm: exploreVM)
            }

            if appState.experimentalLiveTv {
                Tab(String(localized: "Live TV", bundle: AppState.currentBundle), systemImage: "tv", value: 2) {
                    LiveTvView(vm: liveTvVM, playerVM: liveTvPlayerVM)
                }
            }

            if appState.showDownloadsTab {
                Tab(String(localized: "Downloads", bundle: AppState.currentBundle), systemImage: "tray.and.arrow.down.fill", value: 3) {
                    DownloadsView()
                }
            }

            // System search tab: separate round button that expands into the search field.
            Tab(String(localized: "Search", bundle: AppState.currentBundle), systemImage: "magnifyingglass", value: 4, role: .search) {
                SearchView(isTab: true)
            }
        }
        .zoomScope()
        // Selecting the search tab activates the field (and cancel returns to the previous tab).
        // On iOS 27 this is also what makes the search tab get the separate prominent slot.
        .tabViewSearchActivation(.searchTabSelection)
        .overlay(alignment: .top) {
            if let banner = downloadBanner {
                downloadBannerView(banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .animation(.spring(duration: 0.35), value: downloadBanner?.id)
        .sheet(isPresented: $appState.showPaywall) {
            PaywallView()
                .environmentObject(appState)
        }
        .onChange(of: appState.showDownloadsTab) { _, shown in
            if !shown && selectedTab == 3 { selectedTab = 0 }
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            // Leaving Live TV → start PiP if playing
            if oldTab == 2 && newTab != 2 && liveTvPlayerVM.isPlaying && liveTvPlayerVM.isPipSupported {
                liveTvPlayerVM.togglePip()
            }
            // Returning to Live TV → stop PiP, video returns to inline
            if newTab == 2 && liveTvPlayerVM.isPipActive {
                liveTvPlayerVM.togglePip()
            }
        }
        .task(id: appState.serverValidated) {
            guard appState.serverValidated else { return }
            await vm.load(appState: appState)
            Task { await exploreVM.load(appState: appState) }
            Task { await liveTvVM.load(appState: appState) }
        }
        .task(id: appState.sessionId) {
            // Session changed (account switch) → reload if already validated
            guard appState.serverValidated else { return }
            await vm.load(appState: appState)
            Task { await exploreVM.load(appState: appState) }
            Task { await liveTvVM.load(appState: appState) }
        }
        .onReceive(dm.downloadStarted) { started in
            bannerTask?.cancel()
            withAnimation { downloadBanner = started }
            bannerTask = Task {
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                withAnimation { downloadBanner = nil }
            }
        }
    }

    private func downloadBannerView(_ entry: PausedDownload) -> some View {
        Button {
            withAnimation { downloadBanner = nil }
            bannerTask?.cancel()
            if appState.showDownloadsTab { selectedTab = 3 } else { selectedTab = 0; homePath.append(SettingsRoute.downloads) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Download Started", bundle: AppState.currentBundle))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(entry.seriesName.map { "\($0) · " + entry.name } ?? entry.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Main Tab

    private var mainTab: some View {
        NavigationStack(path: $homePath) {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {

                    // Hero Banner
                    if vm.isLoading {
                        HeroBannerPlaceholder()
                    } else if !vm.featuredItems.isEmpty {
                        HeroBannerView(
                            items: vm.featuredItems,
                            serverURL: vm.serverURL,
                            pullDown: heroPullDown,
                            scrollOffset: heroScrollOffset,
                            onPlay: { item in
                                homePath.append(item)
                            },
                        )
                    }

                    // Content
                    VStack(alignment: .leading, spacing: 32) {
                        if appState.showContinueWatching && !vm.continueWatching.isEmpty {
                            continueWatchingSection
                        }
                        if appState.showNextUp && !vm.nextUp.isEmpty {
                            nextUpSection
                        }
                        if appState.showLatestMovies && !vm.latestMovies.isEmpty {
                            latestMoviesSection
                        }
                        if appState.showLatestShows && !vm.latestShows.isEmpty {
                            latestShowsSection
                        }
                        if !vm.isLoading && vm.continueWatching.isEmpty && vm.nextUp.isEmpty &&
                           vm.latestMovies.isEmpty && vm.latestShows.isEmpty {
                            emptyView
                        }
                    }
                    .padding(.top, 28)
                    .padding(.bottom, 40)
                }
            }
            .ignoresSafeArea(edges: .top)
            .scrollEdgeEffectStyle(.none, for: .top)
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { old, offset in
                heroPullDown = max(0, -offset)
                heroScrollOffset = max(0, offset)
                let delta = offset - old
                if delta > 4 && offset > 50 {
                    withAnimation(.easeOut(duration: 0.25)) { showOverlay = false }
                } else if delta < -4 || offset < 50 {
                    withAnimation(.easeOut(duration: 0.25)) { showOverlay = true }
                }
            }
            // Black canvas + drifting mesh tinted by the featured artwork, owned by the
            // navigation container so it stays put while pages slide.
            .ambientPage()
            .coordinateSpace(name: "homeScroll")
            .navigationBarHidden(true)
            .overlay(alignment: .top) {
                HStack {
                    Text(String(localized: "Home", bundle: AppState.currentBundle))
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)

                    Spacer()

                    serverBadge
                        .scaleEffect(badgeBounce ? 0.85 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.4), value: badgeBounce)
                        .onTapGesture { homePath.append(SettingsRoute.settings) }
                        .onLongPressGesture(minimumDuration: 0.5, pressing: { pressing in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                badgeBounce = pressing
                            }
                        }) {
                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                            switchToNextAccount()
                            badgeBounce = false
                        }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .frame(minHeight: 44)
                .opacity(showOverlay ? 1 : 0)
                .offset(y: showOverlay ? 0 : -20)
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .settings:
                    SettingsView(pathBased: true)
                case .downloadSettings:
                    StorageSettingsView(showsDownloadsLink: true)
                        .environmentObject(appState)
                case .downloads:
                    DownloadsView(embedded: true)
                }
            }
            .navigationDestination(for: JellyfinItem.self) { item in
                ItemDetailView(item: item)
            }
            .navigationDestination(item: $autoPlayItem) { item in
                ItemDetailView(item: item, autoPlay: true)
            }
            .navigationDestination(for: JellyfinLibrary.self) { library in
                LibraryView(library: library)
            }
            .overlay(alignment: .bottom) {
                if let error = vm.error {
                    errorBanner(message: error)
                }
            }
            .fullScreenCover(item: $heroPlayItem, onDismiss: {
                appState.isPlayerActive = false
                AppDelegate.orientationLock = .portrait
                PlayerContainerView.rotate(to: .portrait)
            }) { item in
                PlayerContainerView(item: item)
                    .environmentObject(appState)
                    .onAppear { appState.isPlayerActive = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playbackStopped)) { _ in
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    await vm.load(appState: appState)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .personFilmographySelected)) { notification in
                if let item = notification.object as? JellyfinItem {
                    homePath.append(item)
                }
            }
        }
    }

    // MARK: - Server Badge (top-left, over hero)

    private var serverBadge: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(appState.username)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                Text(activeDisplayLabel)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.middle)
                    .foregroundStyle(.white.opacity(0.75))
                    .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
            }

            avatarCircle
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var avatarCircle: some View {
        let url: URL? = {
            if let local = DownloadManager.localUserAvatarURL(userId: appState.userId) { return local }
            guard !appState.manualOffline else { return nil }
            // AsyncImage cannot send headers → token as `ApiKey` query.
            return JellyfinMediaRequestBuilder.mediaURL(
                serverURL: appState.serverURL, path: "Users/\(appState.userId)/Images/Primary",
                queryItems: [URLQueryItem(name: "maxWidth", value: "80")],
                token: appState.token)
        }()
        return AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img):
                img.resizable()
                   .scaledToFill()
                   .frame(width: 48, height: 48)
                   .clipShape(Circle())
            default:
                Circle()
                    .fill(.white.opacity(0.25))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Text(appState.username.prefix(1).uppercased())
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
    }

    private var activeDisplayLabel: String {
        appState.savedAccounts
            .first(where: { $0.id == "\(appState.userId)@\(appState.serverURL)" })?
            .displayLabel
            ?? URL(string: appState.serverURL)?.host
            ?? appState.serverURL
    }

    private func switchToNextAccount() {
        // Only cycle through the same user's servers
        let sameUser = appState.savedAccounts.filter { $0.userId == appState.userId }
        guard sameUser.count > 1 else { return }
        let currentId = "\(appState.userId)@\(appState.serverURL)"
        let currentIdx = sameUser.firstIndex(where: { $0.id == currentId }) ?? 0
        for offset in 1..<sameUser.count {
            let next = sameUser[(currentIdx + offset) % sameUser.count]
            if appState.switchAccount(next) { return }
        }
    }

    // MARK: - Sections

    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "\(String(localized: "Continue Watching", bundle: AppState.currentBundle))")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(vm.continueWatching) { item in
                        Button {
                            autoPlayItem = item
                        } label: {
                            BackdropCardView(item: item, serverURL: vm.serverURL, width: 280, showPlayOverlay: true, overlayMenu: { cardContextMenu(item: item) })
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            cardContextMenu(item: item)
                        } preview: {
                            BackdropCardView(item: item, serverURL: vm.serverURL, showPlayOverlay: true)
                                .padding()
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var nextUpSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "\(String(localized: "Next Up", bundle: AppState.currentBundle))")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(vm.nextUp) { item in
                        Button {
                            autoPlayItem = item
                        } label: {
                            BackdropCardView(item: item, serverURL: vm.serverURL, width: 280, showPlayOverlay: true, overlayMenu: { cardContextMenu(item: item) })
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            cardContextMenu(item: item)
                        } preview: {
                            BackdropCardView(item: item, serverURL: vm.serverURL, showPlayOverlay: true)
                                .padding()
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    @ViewBuilder
    private func cardContextMenu(item: JellyfinItem) -> some View {
        let isPlayed = item.userData?.played ?? false
        let isPartial = !isPlayed && (item.userData?.playbackPositionTicks ?? 0) > 0

        // Navigate to detail page — episode goes to its series with correct season
        Button {
            homePath.append(item)
        } label: {
            Label(String(localized: "Go to Detail", bundle: AppState.currentBundle), systemImage: "arrow.right.circle")
        }

        if !isPlayed {
            Button {
                Task {
                    try? await JellyfinAPI.shared.setPlayed(
                        serverURL: appState.serverURL, itemId: item.id,
                        userId: appState.userId, token: appState.token, played: true)
                    await vm.load(appState: appState)
                }
            } label: {
                Label(String(localized: "Watched", bundle: AppState.currentBundle), systemImage: "eye.fill")
            }
        }

        if isPlayed || isPartial {
            Button(role: isPlayed ? .destructive : .none) {
                Task {
                    try? await JellyfinAPI.shared.setPlayed(
                        serverURL: appState.serverURL, itemId: item.id,
                        userId: appState.userId, token: appState.token, played: false)
                    await vm.load(appState: appState)
                }
            } label: {
                Label(
                    isPlayed
                        ? String(localized: "Remove", bundle: AppState.currentBundle)
                        : String(localized: "Unwatched", bundle: AppState.currentBundle),
                    systemImage: isPlayed ? "xmark.circle" : "eye.slash.fill"
                )
            }
        }
    }

    private var latestMoviesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "\(String(localized: "Latest Movies", bundle: AppState.currentBundle))")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(vm.latestMovies) { item in
                        NavigationLink(value: item) {
                            PosterCardView(item: item, serverURL: vm.serverURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var latestShowsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "\(String(localized: "Latest TV Shows", bundle: AppState.currentBundle))")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(vm.latestShows) { item in
                        NavigationLink(value: item) {
                            PosterCardView(item: item, serverURL: vm.serverURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var librariesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "\(String(localized: "Libraries", bundle: AppState.currentBundle))")
            VStack(spacing: 8) {
                ForEach(vm.libraries) { library in
                    NavigationLink(value: library) {
                        LibraryCardView(library: library)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - States

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(String(localized: "No Content Found", bundle: AppState.currentBundle))
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(JGColor.warning)
            Text(message)
                .font(.caption)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}

// MARK: - Shimmer Placeholder

struct ShimmerRowView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 140, height: 18)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(0..<5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.quaternary)
                            .frame(width: 120, height: 180)
                    }
                }
                .padding(.horizontal, 20)
            }
            .disabled(true)
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    /// true on the Home stack, where settings pages are path values (see `SettingsRoute`).
    var pathBased = false
    @EnvironmentObject private var appState: AppState
    @State private var showAddAccountSheet = false
    @State private var showLogoutAlert = false
    @State private var accountToRemove: SavedAccount?
    @State private var editAliasAccount: SavedAccount?

    @State private var quickConnectAvailable = false
    @State private var showQuickConnectOff = false
    @State private var showQuickConnect = false

    private var appVersion: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    // MARK: Design tokens

    /// Same corner radius as the grouped lists on the settings sub-pages.
    private static let cardRadius: CGFloat = 26

    private static let brandGradient = JGColor.brandGradient
    private static let goldGradient = JGColor.goldGradient

    private func loc(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: AppState.currentBundle)
    }

    /// Rounded icon badge in the app colour — one visual language for every option.
    private func iconBadge(_ icon: String, size: CGFloat = 32, muted: Bool = false) -> some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                if muted { shape.fill(Color.white.opacity(0.16)) } else { shape.fill(Self.brandGradient) }
            }
    }

    // MARK: Current-value summaries (so a tile says something before it is opened)

    private var playbackSummary: String {
        "\(appState.playerEngine.rawValue) · \(appState.defaultVideoQuality.displayName)"
    }

    private var languageSummary: String {
        let parts = [appState.preferredAudioLanguage, appState.preferredSubtitleLanguage]
            .filter { !$0.isEmpty }
            .map { $0.uppercased() }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var downloadsSummary: String {
        let bytes = DownloadManager.shared.downloads.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }
        guard bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var homeSummary: String {
        let on = [appState.showContinueWatching, appState.showNextUp,
                  appState.showLatestMovies, appState.showLatestShows].filter { $0 }.count
        return "\(on) / 4"
    }

    private var appLanguageSummary: String {
        let code = appState.appLanguage
        guard code.count <= 3, let name = Locale.current.localizedString(forLanguageCode: code) else { return "" }
        return name.capitalized
    }

    // MARK: Building blocks

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.top, 10)
    }

    /// Primary option: badge + chevron on top, title and its current value below.
    private func tileLabel(_ key: String.LocalizationValue, icon: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                iconBadge(icon, size: 38)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 18)
            Text(loc(key))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(14)
        .glassCard(cornerRadius: Self.cardRadius, bordered: false)
    }

    private func tile<Destination: View>(_ key: String.LocalizationValue, icon: String, value: String,
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink { destination() } label: { tileLabel(key, icon: icon, value: value) }
            .buttonStyle(.plain)
    }

    /// Secondary option: one line inside a grouped card.
    private func rowLabel(_ key: String.LocalizationValue, icon: String, value: String = "",
                          muted: Bool = false, chevron: Bool = true) -> some View {
        HStack(spacing: 12) {
            iconBadge(icon, size: 30, muted: muted)
            Text(loc(key))
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if !value.isEmpty {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    private var rowDivider: some View {
        Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 56)
    }

    // MARK: Sections

    private var profileHeader: some View {
        HStack(spacing: 14) {
            Text(appState.username.prefix(1).uppercased())
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Self.brandGradient, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(appState.username)
                        .font(.title2.bold())
                        .lineLimit(1)
                    if appState.isPro {
                        Label("PRO", systemImage: "crown.fill")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Self.goldGradient, in: Capsule())
                    }
                }
                Text(appState.serverName.isEmpty
                     ? (URL(string: appState.serverURL)?.host ?? appState.serverURL)
                     : appState.serverName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            Button {
                if !appState.isPro && !appState.savedAccounts.isEmpty {
                    appState.showPaywall = true
                } else {
                    showAddAccountSheet = true
                }
            } label: {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.09), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc("Add"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private var proBanner: some View {
        Button {
            appState.showPaywall = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 38, height: 38)
                    .background(Self.goldGradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(loc("Upgrade to Pro"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .glassCard(cornerRadius: Self.cardRadius, bordered: false)
            .overlay(RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                .strokeBorder(Self.goldGradient.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var primaryTiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            tile("Playback", icon: "play.fill", value: playbackSummary) {
                PlaybackSettingsView().environmentObject(appState)
            }
            tile("Audio & Subtitles", icon: "captions.bubble.fill", value: languageSummary) {
                AudioSubtitleSettingsView().environmentObject(appState)
            }
            if pathBased {
                NavigationLink(value: SettingsRoute.downloadSettings) {
                    tileLabel("Download Settings", icon: "arrow.down.to.line", value: downloadsSummary)
                }
                .buttonStyle(.plain)
            } else {
                tile("Download Settings", icon: "arrow.down.to.line", value: downloadsSummary) {
                    StorageSettingsView().environmentObject(appState)
                }
            }
            tile("Live TV", icon: "tv.fill", value: appState.experimentalLiveTv ? loc("On") : loc("Off")) {
                LiveTvSettingsView().environmentObject(appState)
            }
        }
    }

    /// Server access: authorising another device, and working without the server.
    private var connectionCard: some View {
        VStack(spacing: 0) {
            // Always listed so the card does not jump when the server check comes back.
            Button {
                if quickConnectAvailable { showQuickConnect = true } else { showQuickConnectOff = true }
            } label: {
                rowLabel("Quick Connect", icon: "bolt.fill")
            }
            .buttonStyle(.plain)

            rowDivider
            Toggle(isOn: $appState.manualOffline) {
                HStack(spacing: 12) {
                    iconBadge("wifi.slash", size: 30)
                    Text(loc("Offline"))
                }
            }
            .tint(JGColor.brand)
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
        }
        .glassCard(cornerRadius: Self.cardRadius, bordered: false)
    }

    /// Set-once options: layout of the home screen, language, about.
    private var appCard: some View {
        VStack(spacing: 0) {
            NavigationLink {
                HomeSectionsSettingsView().environmentObject(appState)
            } label: {
                rowLabel("Home Screen", icon: "house.fill", value: homeSummary)
            }
            .buttonStyle(.plain)

            rowDivider
            NavigationLink {
                AppSettingsView().environmentObject(appState)
            } label: {
                rowLabel("App Language", icon: "globe", value: appLanguageSummary)
            }
            .buttonStyle(.plain)

            rowDivider
            NavigationLink {
                AboutSettingsView()
            } label: {
                rowLabel("About", icon: "info", muted: true)
            }
            .buttonStyle(.plain)
        }
        .glassCard(cornerRadius: Self.cardRadius, bordered: false)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button(role: .destructive) {
                showLogoutAlert = true
            } label: {
                Label(loc("Sign Out"), systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(JGColor.danger)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.07), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            Text("JellyGo \(appVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                profileHeader
                accountsSection

                if !appState.isPro {
                    proBanner
                }

                // Most used first: what and how you watch, then server access, then set-once options.
                sectionHeader(loc("Watching"))
                primaryTiles

                sectionHeader(loc("Connection"))
                connectionCard

                sectionHeader(loc("App"))
                appCard

                footer
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 36)
        }
        .brandPage()
        .navigationTitle(String(localized: "Settings", bundle: AppState.currentBundle))
        .task { quickConnectAvailable = (try? await JellyfinAPI.shared.quickConnectEnabled(serverURL: appState.serverURL)) ?? false }
        .alert(loc("Quick Connect"), isPresented: $showQuickConnectOff) {
            Button(loc("OK"), role: .cancel) {}
        } message: {
            Text(loc("Quick Connect is turned off on this server."))
        }
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showAddAccountSheet) {
            ServerView(compact: true)
                .environmentObject(appState)
                .fittedSheet()
                .onAppear { appState.isAddingAccount = true }
                .onDisappear { appState.isAddingAccount = false }
        }
        .sheet(isPresented: $showQuickConnect) {
            QuickConnectView(asSheet: true)
                .environmentObject(appState)
                .fittedSheet()
        }
        .sheet(item: $editAliasAccount) { account in
            AliasEditSheet(account: account)
                .environmentObject(appState)
        }
        // Close sheet when a new account is added
        .onChange(of: appState.savedAccounts.count) { _, _ in
            if showAddAccountSheet { showAddAccountSheet = false }
        }
        // Close sheet when duplicate is confirmed (OK tapped in LoginView alert)
        .onChange(of: appState.closeAddAccountSheet) { _, close in
            if close {
                showAddAccountSheet = false
                appState.closeAddAccountSheet = false
            }
        }
        .alert(String(localized: "Sign Out", bundle: AppState.currentBundle), isPresented: $showLogoutAlert) {
            Button(String(localized: "Sign Out", bundle: AppState.currentBundle), role: .destructive) { appState.logout() }
            Button(String(localized: "Cancel", bundle: AppState.currentBundle), role: .cancel) {}
        } message: {
            Text(String(format: String(localized: "Sign out of %@?", bundle: AppState.currentBundle), appState.username))
        }
        .alert(String(localized: "Remove Account", bundle: AppState.currentBundle), isPresented: Binding(
            get: { accountToRemove != nil },
            set: { if !$0 { accountToRemove = nil } })) {
            Button(String(localized: "Remove", bundle: AppState.currentBundle), role: .destructive) {
                if let account = accountToRemove { appState.removeAccount(account) }
                accountToRemove = nil
            }
            Button(String(localized: "Cancel", bundle: AppState.currentBundle), role: .cancel) { accountToRemove = nil }
        } message: {
            Text(String(format: String(localized: "Remove %@ from this device?", bundle: AppState.currentBundle), accountToRemove?.username ?? ""))
        }
    }

    // MARK: Accounts (outside List — avoids row-level highlight on long press)

    /// Other servers of the signed-in user and the other saved users, right under the
    /// profile header (which already shows the active account). Hidden when there is
    /// nothing else to switch to.
    private var switchableGroups: [UserGroup] {
        userGroups.filter { $0.userId != appState.userId || $0.accounts.count > 1 }
    }

    @ViewBuilder private var accountsSection: some View {
        if !switchableGroups.isEmpty {
            VStack(spacing: 0) {
                ForEach(switchableGroups) { group in
                    userGroupRow(group)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .glassCard(cornerRadius: Self.cardRadius, bordered: false)
        }
    }

    private struct UserGroup: Identifiable {
        let userId: String
        let username: String
        let accounts: [SavedAccount]
        var id: String { userId }
    }

    private var userGroups: [UserGroup] {
        var seen = Set<String>()
        var groups: [UserGroup] = []
        for account in appState.savedAccounts {
            guard !seen.contains(account.userId) else { continue }
            seen.insert(account.userId)
            let userAccounts = appState.savedAccounts.filter { $0.userId == account.userId }
            groups.append(UserGroup(userId: account.userId, username: account.username, accounts: userAccounts))
        }
        return groups
    }

    @ViewBuilder
    private func userGroupRow(_ group: UserGroup) -> some View {
        let isCurrentUser = group.userId == appState.userId

        VStack(alignment: .leading, spacing: 0) {
            // User header (the active user is already in the profile header above)
            if !isCurrentUser {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isCurrentUser ? AnyShapeStyle(Self.brandGradient) : AnyShapeStyle(Color.white.opacity(0.12)))
                        .frame(width: 36, height: 36)
                    Text(group.username.prefix(1).uppercased())
                        .font(.headline.bold())
                        .foregroundStyle(isCurrentUser ? .white : .secondary)
                }

                Text(group.username)
                    .font(.subheadline.weight(.semibold))

                if isCurrentUser {
                    Text(String(localized: "Active", bundle: AppState.currentBundle))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }

                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            }

            // Server rows indented under user
            VStack(spacing: 0) {
                ForEach(group.accounts) { account in
                    serverRow(account)
                }
            }
            .padding(.leading, isCurrentUser ? 0 : 52)
        }

        if group.id != switchableGroups.last?.id {
            Divider().padding(.leading, 56)
        }
    }

    @ViewBuilder
    private func serverRow(_ account: SavedAccount) -> some View {
        let isActive = account.id == "\(appState.userId)@\(appState.serverURL)"

        Button {
            if !isActive { _ = withAnimation { appState.switchAccount(account) } }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .font(.body)

                VStack(alignment: .leading, spacing: 1) {
                    Text(account.displayLabel)
                        .font(.subheadline)
                        .foregroundStyle(isActive ? .primary : .secondary)
                    Text(account.serverURL)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { editAliasAccount = account } label: {
                Label(String(localized: "Edit Label", bundle: AppState.currentBundle), systemImage: "tag")
            }
            Button(role: .destructive) { accountToRemove = account } label: {
                Label(String(localized: "Remove", bundle: AppState.currentBundle), systemImage: "trash")
            }
        }
    }


}

// MARK: - Quick Connect View

/// Row background for the settings sub-pages: the same translucent glass as the cards
/// on the main Settings page (the list clips it to its rounded sections).
struct SettingsRowBackground: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Color.white.opacity(0.04))
    }
}

struct QuickConnectView: View {
    /// true when shown as a compact sheet from Settings instead of a pushed page.
    var asSheet = false
    @EnvironmentObject private var appState: AppState
    @FocusState private var codeFocused: Bool
    @State private var quickConnectCode = ""
    @State private var quickConnectAuthorizing = false
    @State private var quickConnectSuccess = false
    @State private var quickConnectError: String?

    var body: some View {
        if asSheet { sheetBody } else { pageBody }
    }

    /// Same look as the server-entry form on the welcome screen (shared Auth* components).
    private var sheetBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Quick Connect", bundle: AppState.currentBundle))
                    .font(.title2.bold())
                Text(String(localized: "Enter the code shown on the device you want to authorize.", bundle: AppState.currentBundle))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 4)

            AuthFormCard(header: String(localized: "Quick Connect Code", bundle: AppState.currentBundle)) {
                VStack(spacing: 14) {
                    AuthInputField(icon: "bolt.fill", chip: "code", placeholder: "000000",
                                   text: $quickConnectCode, keyboard: .numberPad, monospaced: true,
                                   isError: quickConnectError != nil, isFocused: codeFocused)
                        .focused($codeFocused)
                        .onChange(of: quickConnectCode) { _, _ in quickConnectError = nil }

                    if let error = quickConnectError {
                        AuthErrorLine(message: error)
                    }

                    AuthPrimaryButton(title: String(localized: "Authorize", bundle: AppState.currentBundle),
                                      systemImage: "checkmark.shield",
                                      isLoading: quickConnectAuthorizing,
                                      isDone: quickConnectSuccess,
                                      isEnabled: !quickConnectCode.isEmpty) {
                        codeFocused = false
                        Task { await authorizeQuickConnect() }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .onAppear { codeFocused = true }
    }

    private var pageBody: some View {
        List {
        Group {
            Section {
                HStack(spacing: 12) {
                    TextField(String(localized: "Quick Connect Code", bundle: AppState.currentBundle), text: $quickConnectCode)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.plain)
                        .disabled(quickConnectAuthorizing)

                    if quickConnectAuthorizing {
                        ProgressView().scaleEffect(0.8)
                    } else if quickConnectSuccess {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(JGColor.success)
                    } else {
                        Button {
                            Task { await authorizeQuickConnect() }
                        } label: {
                            Text(String(localized: "Authorize", bundle: AppState.currentBundle))
                                .font(.subheadline.weight(.medium))
                        }
                        .disabled(quickConnectCode.isEmpty)
                    }
                }

                if let error = quickConnectError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(JGColor.danger)
                }
            } footer: {
                Text(String(localized: "Enter the code shown on the device you want to authorize.", bundle: AppState.currentBundle))
            }
        }
        .listRowBackground(SettingsRowBackground())
        }
        .ambientList()
        .navigationTitle(String(localized: "Quick Connect", bundle: AppState.currentBundle))
        .toolbar(.hidden, for: .tabBar)
    }

    private func authorizeQuickConnect() async {
        quickConnectError = nil
        quickConnectSuccess = false
        quickConnectAuthorizing = true
        defer { quickConnectAuthorizing = false }

        do {
            try await JellyfinAPI.shared.quickConnectAuthorize(
                serverURL: appState.serverURL,
                code: quickConnectCode,
                token: appState.token
            )
            quickConnectSuccess = true
            quickConnectCode = ""
            Task {
                try? await Task.sleep(for: .seconds(3))
                quickConnectSuccess = false
            }
        } catch JellyfinAPIError.serverError(let status) where status == 404 || status == 400 {
            // The server answers 404 for a code it does not know (mistyped or expired).
            quickConnectError = String(localized: "Invalid or expired code. Check it and try again.",
                                       bundle: AppState.currentBundle)
        } catch let error as JellyfinAPIError {
            quickConnectError = error.errorDescription
        } catch {
            quickConnectError = error.localizedDescription
        }
    }
}

// MARK: - Playback Settings

struct PlaybackSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
        Group {
            Section(String(localized: "Player Engine", bundle: AppState.currentBundle)) {
                Picker(String(localized: "Player Engine", bundle: AppState.currentBundle),
                       selection: $appState.playerEngine) {
                    ForEach(PlayerEngine.allCases) { engine in
                        Text(engine.rawValue).tag(engine)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section(String(localized: "Default Quality", bundle: AppState.currentBundle)) {
                Picker(String(localized: "Default Quality", bundle: AppState.currentBundle), selection: $appState.defaultVideoQuality) {
                    ForEach(VideoQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .listRowBackground(SettingsRowBackground())
        }
        .ambientList()
        .navigationTitle(String(localized: "Playback", bundle: AppState.currentBundle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Audio & Subtitle Settings

struct AudioSubtitleSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
        Group {
            Section(String(localized: "Audio", bundle: AppState.currentBundle)) {
                LanguagePicker(
                    label: "Preferred Language",
                    selection: $appState.preferredAudioLanguage,
                    includeOff: false
                )
            }

            Section(String(localized: "Subtitles", bundle: AppState.currentBundle)) {
                Toggle(String(localized: "Enable by Default", bundle: AppState.currentBundle), isOn: $appState.subtitlesEnabledByDefault)

                if appState.subtitlesEnabledByDefault {
                    LanguagePicker(
                        label: "Preferred Language",
                        selection: $appState.preferredSubtitleLanguage,
                        includeOff: false
                    )
                    LanguagePicker(
                        label: "Secondary Language",
                        selection: $appState.secondarySubtitleLanguage,
                        includeOff: true
                    )
                }

                NavigationLink(String(localized: "Subtitle Appearance", bundle: AppState.currentBundle)) {
                    SubtitleAppearanceView()
                        .environmentObject(appState)
                }
            }
        }
        .listRowBackground(SettingsRowBackground())
        }
        .ambientList()
        .navigationTitle(String(localized: "Audio & Subtitles", bundle: AppState.currentBundle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - App Settings

struct AppSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
        Group {
            Section(String(localized: "Language Settings", bundle: AppState.currentBundle)) {
                AppLanguagePicker(selection: $appState.appLanguage)
            }
        }
        .listRowBackground(SettingsRowBackground())
        }
        .ambientList()
        .navigationTitle(String(localized: "App Language", bundle: AppState.currentBundle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - About Settings

struct AboutSettingsView: View {
    private var appVersion: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        List {
        Group {
            Section {
                LabeledContent(String(localized: "Version", bundle: AppState.currentBundle), value: appVersion)
                    .foregroundStyle(.secondary)
            }
            Section {
                Link(destination: URL(string: "https://jellyfin.org")!) {
                    Label(String(localized: "Jellyfin Project", bundle: AppState.currentBundle), systemImage: "link")
                }
            }
            Section {
                HStack(spacing: 10) {
                    Image("TMDbLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 16)
                    Text(String(localized: "This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.", bundle: AppState.currentBundle))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .listRowBackground(SettingsRowBackground())
        }
        .ambientList()
        .navigationTitle(String(localized: "About", bundle: AppState.currentBundle))
        .navigationBarTitleDisplayMode(.inline)
    }
}


// MARK: - Home Sections Settings

struct HomeSectionsSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
        Group {
            Section {
                Toggle(String(localized: "Continue Watching", bundle: AppState.currentBundle), isOn: $appState.showContinueWatching)
                Toggle(String(localized: "Next Up", bundle: AppState.currentBundle), isOn: $appState.showNextUp)
                Toggle(String(localized: "Latest Movies", bundle: AppState.currentBundle), isOn: $appState.showLatestMovies)
                Toggle(String(localized: "Latest TV Shows", bundle: AppState.currentBundle), isOn: $appState.showLatestShows)
            } footer: {
                Text(String(localized: "Choose which sections appear on the home screen.", bundle: AppState.currentBundle))
            }
        }
        .listRowBackground(SettingsRowBackground())
        }
        .ambientList()
        .navigationTitle(String(localized: "Home Screen", bundle: AppState.currentBundle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Storage Settings

struct StorageSettingsView: View {
    var showsDownloadsLink = false
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dm: DownloadManager
    @State private var totalDownloadSize: String = "—"
    @State private var cacheSize: String = "—"
    @State private var showClearCacheAlert = false
    @State private var showDeleteAllAlert = false
    @State private var itemToDelete: DownloadedItem?

    // Movies sorted alphabetically
    private var movies: [DownloadedItem] {
        dm.downloads.filter(\.isMovie).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // Series grouped, each with seasons, each with sorted episodes
    private var seriesGroups: [StorageSeriesGroup] {
        var dict: [String: StorageSeriesGroup] = [:]
        for ep in dm.downloads where ep.isEpisode {
            let key = ep.seriesId ?? ep.seriesName ?? ep.id
            if dict[key] == nil {
                dict[key] = StorageSeriesGroup(id: key, name: ep.seriesName ?? ep.name, episodes: [])
            }
            dict[key]!.episodes.append(ep)
        }
        for key in dict.keys {
            dict[key]!.episodes.sort {
                let s0 = $0.seasonNumber ?? 0, s1 = $1.seasonNumber ?? 0
                if s0 != s1 { return s0 < s1 }
                return ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0)
            }
        }
        return dict.values.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
        Group {
            // Where Downloads lives
            // Offline mode keeps its own Downloads tab, so the link only exists on the Home stack.
            if showsDownloadsLink {
                Section {
                    NavigationLink(value: SettingsRoute.downloads) {
                        Label(String(localized: "Downloads", bundle: AppState.currentBundle), systemImage: "tray.and.arrow.down")
                    }
                }
            }

            Section {
                Toggle(String(localized: "Downloads Tab", bundle: AppState.currentBundle), isOn: $appState.showDownloadsTab)
            } footer: {
                Text(String(localized: "Shows Downloads as a tab at the bottom of the screen.", bundle: AppState.currentBundle))
            }

            // Summary
            Section {
                LabeledContent(String(localized: "Downloaded Content", bundle: AppState.currentBundle), value: totalDownloadSize)
                LabeledContent(String(localized: "Image Cache", bundle: AppState.currentBundle), value: cacheSize)
            }

            // Movies
            if !movies.isEmpty {
                Section(String(localized: "Movies", bundle: AppState.currentBundle)) {
                    ForEach(movies) { movie in
                        storageRow(
                            title: movie.name,
                            subtitle: [movie.productionYear.map { String($0) }, movie.qualityDisplayName, movie.formattedSize.isEmpty ? nil : movie.formattedSize]
                                .compactMap { $0 }.joined(separator: " · "),
                            itemId: movie.id,
                            isMovie: true
                        ) {
                            itemToDelete = movie
                        }
                    }
                }
            }

            // Series
            ForEach(seriesGroups) { series in
                Section {
                    ForEach(series.episodes) { ep in
                        storageRow(
                            title: {
                                if let s = ep.seasonNumber, let e = ep.episodeNumber {
                                    return "S\(s)E\(e) — \(ep.name)"
                                }
                                return ep.name
                            }(),
                            subtitle: [ep.qualityDisplayName, ep.formattedSize.isEmpty ? nil : ep.formattedSize]
                                .compactMap { $0 }.joined(separator: " · "),
                            itemId: ep.id,
                            isMovie: false
                        ) {
                            itemToDelete = ep
                        }
                    }
                } header: {
                    HStack {
                        Text(series.name)
                        Spacer()
                        Text(formatBytes(series.totalSize))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Actions
            Section {
                Button(role: .destructive) { showClearCacheAlert = true } label: {
                    Label(String(localized: "Clear Cache", bundle: AppState.currentBundle), systemImage: "xmark.bin")
                        .foregroundStyle(JGColor.danger)
                }
                if !dm.downloads.isEmpty {
                    Button(role: .destructive) { showDeleteAllAlert = true } label: {
                        Label(String(localized: "Delete All", bundle: AppState.currentBundle), systemImage: "trash")
                            .foregroundStyle(JGColor.danger)
                    }
                }
            }
        }
        .listRowBackground(SettingsRowBackground())
        }
        .ambientList()
        .navigationTitle(String(localized: "Download Settings", bundle: AppState.currentBundle))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { recalculate() }
        .alert(String(localized: "Delete Download?", bundle: AppState.currentBundle),
               isPresented: Binding(get: { itemToDelete != nil }, set: { if !$0 { itemToDelete = nil } })) {
            Button(String(localized: "Delete", bundle: AppState.currentBundle), role: .destructive) {
                if let item = itemToDelete {
                    withAnimation { dm.deleteDownload(item.id) }
                    recalculate()
                }
                itemToDelete = nil
            }
            Button(String(localized: "Cancel", bundle: AppState.currentBundle), role: .cancel) { itemToDelete = nil }
        } message: {
            if let item = itemToDelete {
                Text(item.isEpisode ? "\(item.seriesName ?? "") — \(item.name)" : item.name)
            }
        }
        .alert(String(localized: "Clear Cache", bundle: AppState.currentBundle), isPresented: $showClearCacheAlert) {
            Button(String(localized: "Clear", bundle: AppState.currentBundle), role: .destructive) {
                URLCache.shared.removeAllCachedResponses()
                recalculate()
            }
            Button(String(localized: "Cancel", bundle: AppState.currentBundle), role: .cancel) {}
        }
        .alert(String(localized: "Delete All", bundle: AppState.currentBundle), isPresented: $showDeleteAllAlert) {
            Button(String(localized: "Delete", bundle: AppState.currentBundle), role: .destructive) {
                dm.deleteAllDownloads(); recalculate()
            }
            Button(String(localized: "Cancel", bundle: AppState.currentBundle), role: .cancel) {}
        }
    }

    // MARK: - Row

    private func storageRow(title: String, subtitle: String, itemId: String, isMovie: Bool, onDelete: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            // Poster
            storagePoster(itemId: itemId, isMovie: isMovie)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button { onDelete() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func storagePoster(itemId: String, isMovie: Bool) -> some View {
        let url = DownloadManager.localPosterURL(itemId: itemId) ?? DownloadManager.localBackdropURL(itemId: itemId)
        if let url {
            AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fill) }
                placeholder: { RoundedRectangle(cornerRadius: 5).fill(.quaternary) }
                .frame(width: 36, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                .frame(width: 36, height: 54)
                .overlay(Image(systemName: isMovie ? "film" : "tv").font(.caption2).foregroundStyle(.tertiary))
        }
    }

    private func recalculate() {
        let dir = DownloadManager.downloadsDirectory
        if let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            var total: Int64 = 0
            for case let f as URL in en {
                if let s = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize { total += Int64(s) }
            }
            totalDownloadSize = formatBytes(total)
        } else { totalDownloadSize = formatBytes(0) }
        cacheSize = formatBytes(Int64(URLCache.shared.currentDiskUsage))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}

private struct StorageSeriesGroup: Identifiable {
    let id: String
    let name: String
    var episodes: [DownloadedItem]
    var totalSize: Int64 { episodes.compactMap(\.fileSize).reduce(0, +) }
}

// MARK: - Alias Edit Sheet

struct AliasEditSheet: View {
    let account: SavedAccount
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var alias: String

    private var host: String { URL(string: account.serverURL)?.host ?? account.serverURL }

    init(account: SavedAccount) {
        self.account = account
        _alias = State(initialValue: account.alias ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "e.g. Home, Remote, VPN…", bundle: AppState.currentBundle), text: $alias)
                        .autocorrectionDisabled()
                } header: {
                    Text(host)
                } footer: {
                    Text(String(localized: "Label shown in the home screen badge and account bubbles. Leave empty to use the server address.", bundle: AppState.currentBundle))
                }
            }
            .navigationTitle(String(localized: "Edit Label", bundle: AppState.currentBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Cancel", bundle: AppState.currentBundle)) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Save", bundle: AppState.currentBundle)) {
                        appState.updateAlias(alias, forAccountId: account.id)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Language Picker

// MARK: - Media Language Picker (for audio/subtitle track preference)

private struct LanguagePicker: View {
    let label: LocalizedStringKey
    @Binding var selection: String
    let includeOff: Bool

    private var languages: [(name: String, code: String)] {
        [
            (String(localized: "System Default"), ""),
            ("Arabic (عربي)", "ara"),
            ("Azerbaijani (Azərbaycanca)", "aze"),
            ("Chinese (中文)", "chi"),
            ("Danish (Dansk)", "dan"),
            ("Dutch (Nederlands)", "nld"),
            ("English", "eng"),
            ("Farsi (فارسی)", "per"),
            ("French (Français)", "fra"),
            ("German (Deutsch)", "deu"),
            ("Italian (Italiano)", "ita"),
            ("Japanese (日本語)", "jpn"),
            ("Korean (한국어)", "kor"),
            ("Polish (Polski)", "pol"),
            ("Portuguese (Português)", "por"),
            ("Russian (Русский)", "rus"),
            ("Spanish (Español)", "spa"),
            ("Swedish (Svenska)", "swe"),
            ("Turkish (Türkçe)", "tur"),
            ("Ukrainian (Українська)", "ukr"),
        ]
    }

    var body: some View {
        Picker(label, selection: $selection) {
            if includeOff {
                Text(String(localized: "Off", bundle: AppState.currentBundle)).tag("off")
            }
            ForEach(languages, id: \.code) { lang in
                Text(verbatim: lang.name).tag(lang.code)
            }
        }
    }
}

// MARK: - App UI Language Picker

private struct AppLanguagePicker: View {
    @Binding var selection: String

    private let uiLanguages: [(name: String, code: String)] = [
        ("System Default", ""),
        ("Azərbaycan dili", "az"),
        ("Dansk", "da"),
        ("Deutsch", "de"),
        ("English", "en"),
        ("Español", "es"),
        ("Français", "fr"),
        ("Italiano", "it"),
        ("日本語", "ja"),
        ("한국어", "ko"),
        ("Nederlands", "nl"),
        ("Português", "pt"),
        ("Русский", "ru"),
        ("Svenska", "sv"),
        ("Türkçe", "tr"),
        ("Українська", "uk"),
        ("فارسی", "fa"),
        ("العربية", "ar"),
        ("中文", "zh"),
    ]

    var body: some View {
        Picker(String(localized: "App Language", bundle: AppState.currentBundle), selection: $selection) {
            ForEach(uiLanguages, id: \.code) { lang in
                Text(verbatim: lang.name).tag(lang.code)
            }
        }
    }
}

// MARK: - Subtitle Appearance View

struct SubtitleAppearanceView: View {
    @EnvironmentObject private var appState: AppState

    private var previewFontSize: CGFloat {
        switch appState.subtitleFontSize {
        case 25: return 14
        case 15: return 22
        case 10: return 28
        default: return 18
        }
    }

    private var previewColor: Color {
        appState.subtitleColor == "yellow" ? .yellow : .white
    }

    var body: some View {
        List {
        Group {
            // Preview
            Section {
                ZStack {
                    LinearGradient(
                        colors: [Color(white: 0.35), Color(white: 0.18)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(spacing: 0) {
                        Spacer()
                        VStack(spacing: previewFontSize * (appState.subtitleLineSpacing - 1.0)) {
                            subtitleLine("The quick brown fox jumps")
                            subtitleLine("over the lazy dog.")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            appState.subtitleBackgroundEnabled
                                ? Color.black.opacity(appState.subtitleBackgroundOpacity)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(.bottom, appState.subtitleBottomPadding * 0.4)
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text(String(localized: "Preview", bundle: AppState.currentBundle))
            }

            // Font Size
            Section(String(localized: "Font Size", bundle: AppState.currentBundle)) {
                Picker(String(localized: "Size", bundle: AppState.currentBundle), selection: $appState.subtitleFontSize) {
                    Text(String(localized: "Small", bundle: AppState.currentBundle)).tag(25)
                    Text(String(localized: "Medium", bundle: AppState.currentBundle)).tag(20)
                    Text(String(localized: "Large", bundle: AppState.currentBundle)).tag(15)
                    Text(String(localized: "Extra Large", bundle: AppState.currentBundle)).tag(10)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            // Style
            Section(String(localized: "Style", bundle: AppState.currentBundle)) {
                Toggle(String(localized: "Bold", bundle: AppState.currentBundle), isOn: $appState.subtitleBold)

                Picker(String(localized: "Color", bundle: AppState.currentBundle), selection: $appState.subtitleColor) {
                    Text(String(localized: "White", bundle: AppState.currentBundle)).tag("white")
                    Text(String(localized: "Yellow", bundle: AppState.currentBundle)).tag("yellow")
                }
            }

            // Background
            Section(String(localized: "Background", bundle: AppState.currentBundle)) {
                Toggle(String(localized: "Background", bundle: AppState.currentBundle), isOn: $appState.subtitleBackgroundEnabled)

                if appState.subtitleBackgroundEnabled {
                    HStack {
                        Text(String(localized: "Opacity", bundle: AppState.currentBundle))
                        Slider(value: $appState.subtitleBackgroundOpacity, in: 0.1...1.0, step: 0.05)
                        Text("\(Int(appState.subtitleBackgroundOpacity * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }

            // Layout
            Section(String(localized: "Layout", bundle: AppState.currentBundle)) {
                HStack {
                    Text(String(localized: "Line Spacing", bundle: AppState.currentBundle))
                    Slider(value: $appState.subtitleLineSpacing, in: 0.8...2.0, step: 0.1)
                    Text(String(format: "%.1fx", appState.subtitleLineSpacing))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }

                HStack {
                    Text(String(localized: "Bottom Offset", bundle: AppState.currentBundle))
                    Slider(value: $appState.subtitleBottomPadding, in: 10...120, step: 5)
                    Text("\(Int(appState.subtitleBottomPadding))pt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .listRowBackground(SettingsRowBackground())
        }
        .ambientList()
        .navigationTitle(String(localized: "Subtitle Appearance", bundle: AppState.currentBundle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    private func subtitleLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: previewFontSize, weight: appState.subtitleBold ? .bold : .medium))
            .foregroundStyle(previewColor)
            .shadow(color: .black, radius: 2, x: 0, y: 1)
            .multilineTextAlignment(.center)
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState())
}
