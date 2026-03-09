import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dm: DownloadManager
    @StateObject private var vm = HomeViewModel()
    @State private var heroPlayItem: JellyfinItem?
    @State private var showSettings = false
    @State private var downloadBanner: PausedDownload?
    @State private var bannerTask: Task<Void, Never>?
    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: 0) {
                mainTab
            }
            Tab("Library", systemImage: "square.grid.2x2.fill", value: 1) {
                LibraryBrowseView()
            }
            Tab("Downloads", systemImage: "arrow.down.circle.fill", value: 2) {
                DownloadsView()
            }
            Tab(value: 3, role: .search) {
                SearchView()
                    .environmentObject(appState)
            }
        }
        .overlay(alignment: .top) {
            if let banner = downloadBanner {
                downloadBannerView(banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .animation(.spring(duration: 0.35), value: downloadBanner?.id)
        .task(id: appState.sessionId) { await vm.load(appState: appState) }
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
            selectedTab = 2
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download Started")
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
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {

                    // Hero Banner
                    if vm.isLoading {
                        HeroBannerPlaceholder()
                    } else if !vm.featuredItems.isEmpty {
                        HeroBannerView(
                            items: vm.featuredItems,
                            serverURL: vm.serverURL,
                            onPlay: { item in
                                AppDelegate.orientationLock = .landscape
                                PlayerContainerView.rotate(to: .landscapeRight)
                                Task {
                                    try? await Task.sleep(for: .milliseconds(300))
                                    heroPlayItem = item
                                }
                            }
                        )
                    }

                    // Content
                    VStack(alignment: .leading, spacing: 32) {
                        if !vm.continueWatching.isEmpty {
                            continueWatchingSection
                        }
                        if !vm.nextUp.isEmpty {
                            nextUpSection
                        }
                        if !vm.latestMovies.isEmpty {
                            latestMoviesSection
                        }
                        if !vm.latestShows.isEmpty {
                            latestShowsSection
                        }
                        if !vm.libraries.isEmpty {
                            librariesSection
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
            .background(Color(.systemBackground).ignoresSafeArea())
            .coordinateSpace(name: "homeScroll")
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { switchToNextAccount() } label: { serverBadge }
                        .buttonStyle(.plain)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                    }
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
            .navigationDestination(for: JellyfinItem.self) { item in
                ItemDetailView(item: item)
            }
            .navigationDestination(for: JellyfinLibrary.self) { library in
                LibraryView(library: library)
            }
            .navigationDestination(for: JellyfinPerson.self) { person in
                PersonDetailView(person: person)
            }
            .overlay(alignment: .bottom) {
                if let error = vm.error {
                    errorBanner(message: error)
                }
            }
            .fullScreenCover(item: $heroPlayItem, onDismiss: {
                AppDelegate.orientationLock = .portrait
                PlayerContainerView.rotate(to: .portrait)
            }) { item in
                PlayerContainerView(item: item)
                    .environmentObject(appState)
            }
            .onReceive(NotificationCenter.default.publisher(for: .playbackStopped)) { _ in
                Task { await vm.load(appState: appState) }
            }
        }
    }

    // MARK: - Server Badge (top-left, over hero)

    private var serverBadge: some View {
        HStack(spacing: 10) {
            avatarCircle

            VStack(alignment: .leading, spacing: 2) {
                Text(appState.username)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                Text(activeDisplayLabel)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
            }
        }
        .padding(.trailing, 16)
        .fixedSize()
    }

    private var avatarCircle: some View {
        var components = URLComponents(string: appState.serverURL)
        components?.path += "/Users/\(appState.userId)/Images/Primary"
        components?.queryItems = [
            URLQueryItem(name: "maxWidth", value: "80"),
            URLQueryItem(name: "api_key",  value: appState.token)
        ]
        return AsyncImage(url: components?.url) { phase in
            switch phase {
            case .success(let img):
                img.resizable()
                   .scaledToFill()
                   .frame(width: 36, height: 36)
                   .clipShape(Circle())
            default:
                Circle()
                    .fill(.white.opacity(0.25))
                    .frame(width: 36, height: 36)
                    .overlay {
                        Text(appState.username.prefix(1).uppercased())
                            .font(.system(size: 15, weight: .semibold))
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
            SectionHeaderView(title: "Continue Watching")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(vm.continueWatching) { item in
                        NavigationLink(value: item) {
                            BackdropCardView(item: item, serverURL: vm.serverURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var nextUpSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "Next Up")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(vm.nextUp) { item in
                        NavigationLink(value: item) {
                            BackdropCardView(item: item, serverURL: vm.serverURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var latestMoviesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "Latest Movies")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
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
            SectionHeaderView(title: "Latest TV Shows")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
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
            SectionHeaderView(title: "Libraries")
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
            Text("No Content Found")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
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
    @EnvironmentObject private var appState: AppState
    @State private var showAddAccountSheet = false
    @State private var showLogoutAlert = false
    @State private var accountToRemove: SavedAccount?
    @State private var editAliasAccount: SavedAccount?

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        List {
            playbackSection
            appLanguageSection
            audioSection
            subtitlesSection
            aboutSection
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            accountsBubbles
        }
        .navigationTitle("Settings")
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showLogoutAlert = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("Sign Out")
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .sheet(isPresented: $showAddAccountSheet) {
            ServerView()
                .environmentObject(appState)
                .onAppear { appState.isAddingAccount = true }
                .onDisappear { appState.isAddingAccount = false }
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
        .alert("Sign Out", isPresented: $showLogoutAlert) {
            Button("Sign Out", role: .destructive) { appState.logout() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sign out of \(appState.username)?")
        }
        .alert("Remove Account", isPresented: Binding(
            get: { accountToRemove != nil },
            set: { if !$0 { accountToRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let account = accountToRemove { appState.removeAccount(account) }
                accountToRemove = nil
            }
            Button("Cancel", role: .cancel) { accountToRemove = nil }
        } message: {
            Text("Remove \(accountToRemove?.username ?? "") from this device?")
        }
    }

    // MARK: Accounts (outside List — avoids row-level highlight on long press)

    private var accountsBubbles: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Accounts")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.leading, 20)
                Spacer()
                Button { showAddAccountSheet = true } label: {
                    Label("Add", systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                        .labelStyle(.iconOnly)
                        .padding(.trailing, 20)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(userGroups) { group in
                    userGroupRow(group)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()
        }
        .background(Color(.systemGroupedBackground))
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
            // User header
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isCurrentUser ? Color.accentColor : Color.secondary.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Text(group.username.prefix(1).uppercased())
                        .font(.headline.bold())
                        .foregroundStyle(isCurrentUser ? .white : .secondary)
                }

                Text(group.username)
                    .font(.subheadline.weight(.semibold))

                if isCurrentUser {
                    Text("Active")
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

            // Server rows indented under user
            VStack(spacing: 0) {
                ForEach(group.accounts) { account in
                    serverRow(account)
                }
            }
            .padding(.leading, 52)
        }

        if group.id != userGroups.last?.id {
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
                Label("Edit Label", systemImage: "tag")
            }
            Button(role: .destructive) { accountToRemove = account } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }


    // MARK: Playback

    private var playbackSection: some View {
        Section("Playback") {
            Picker("Default Quality", selection: $appState.defaultVideoQuality) {
                ForEach(VideoQuality.allCases) { quality in
                    qualityLabel(for: quality).tag(quality)
                }
            }
        }
    }

    private func qualityLabel(for quality: VideoQuality) -> some View {
        Text(quality.rawValue)
    }

    // MARK: App Language

    private var appLanguageSection: some View {
        Section("Language Settings") {
            AppLanguagePicker(selection: $appState.appLanguage)
        }
    }

    // MARK: Audio

    private var audioSection: some View {
        Section("Audio") {
            LanguagePicker(
                label: "Preferred Language",
                selection: $appState.preferredAudioLanguage,
                includeOff: false
            )
        }
    }

    // MARK: Subtitles

    private var subtitlesSection: some View {
        Section("Subtitles") {
            Toggle("Enable by Default", isOn: $appState.subtitlesEnabledByDefault)

            if appState.subtitlesEnabledByDefault {
                LanguagePicker(
                    label: "Preferred Language",
                    selection: $appState.preferredSubtitleLanguage,
                    includeOff: false
                )
            }

            NavigationLink("Subtitle Appearance") {
                SubtitleAppearanceView()
                    .environmentObject(appState)
            }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: appVersion)
                .foregroundStyle(.secondary)
            Link(destination: URL(string: "https://jellyfin.org")!) {
                Label("Jellyfin Project", systemImage: "link")
            }
        }
    }

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
                    TextField("e.g. Home, Remote, VPN…", text: $alias)
                        .autocorrectionDisabled()
                } header: {
                    Text(host)
                } footer: {
                    Text("Label shown in the home screen badge and account bubbles. Leave empty to use the server address.")
                }
            }
            .navigationTitle("Edit Label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
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
                Text("Off").tag("off")
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
        Picker("App Language", selection: $selection) {
            ForEach(uiLanguages, id: \.code) { lang in
                Text(verbatim: lang.name).tag(lang.code)
            }
        }
    }
}

// MARK: - Subtitle Appearance View

struct SubtitleAppearanceView: View {
    @EnvironmentObject private var appState: AppState

    private var previewFont: Font {
        let base: Font = switch appState.subtitleFontSize {
        case 25: .caption
        case 15: .title3
        case 10: .title2
        default: .body
        }
        return appState.subtitleBold ? base.bold() : base
    }

    private var previewColor: Color {
        appState.subtitleColor == "yellow" ? .yellow : .white
    }

    var body: some View {
        List {
            // Preview
            Section {
                ZStack {
                    LinearGradient(
                        colors: [Color(white: 0.12), Color(white: 0.05)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(spacing: 2) {
                        subtitleLine("The quick brown fox jumps")
                        subtitleLine("over the lazy dog.")
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 20)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text("Preview")
            }

            // Font Size
            Section("Font Size") {
                Picker("Size", selection: $appState.subtitleFontSize) {
                    Text("Small").tag(25)
                    Text("Medium").tag(20)
                    Text("Large").tag(15)
                    Text("Extra Large").tag(10)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            // Style
            Section("Style") {
                Toggle("Bold", isOn: $appState.subtitleBold)

                Picker("Color", selection: $appState.subtitleColor) {
                    Text("White").tag("white")
                    Text("Yellow").tag("yellow")
                }

                Toggle("Background Box", isOn: $appState.subtitleBackgroundEnabled)
            }
        }
        .navigationTitle("Subtitle Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    private func subtitleLine(_ text: String) -> some View {
        Text(text)
            .font(previewFont)
            .foregroundStyle(previewColor)
            .padding(.horizontal, appState.subtitleBackgroundEnabled ? 6 : 0)
            .padding(.vertical, appState.subtitleBackgroundEnabled ? 2 : 0)
            .background(appState.subtitleBackgroundEnabled ? Color.black.opacity(0.75) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 3))
            .multilineTextAlignment(.center)
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState())
}
