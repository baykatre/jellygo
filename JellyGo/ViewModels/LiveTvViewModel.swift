import SwiftUI
import Combine

/// Live TV channels from every source: the Jellyfin server (unchanged behaviour) plus the
/// enabled external M3U lists (`ExternalLiveTvStore`). Both arrive as `JellyfinItem`s of
/// type `TvChannel`; external ones carry an id starting with `ExternalLiveTvID.prefix`.
@MainActor
final class LiveTvViewModel: ObservableObject {
    enum SourceFilter: Hashable {
        case all
        case jellyfin
        case external(UUID)
    }

    /// Everything the screen may show (source / group filters are applied by the view).
    @Published var channels: [JellyfinItem] = []
    @Published var isLoading = true
    @Published var error: String?
    @Published var serverURL: String = ""
    @Published var sourceFilter: SourceFilter = .all {
        didSet { if oldValue != sourceFilter { groupFilter = nil } }
    }
    @Published var groupFilter: String?

    private let store = ExternalLiveTvStore.shared
    private var jellyfinChannels: [JellyfinItem] = []
    private var jellyfinError: String?
    private var lastJellyfinFetch: Date = .distantPast

    /// What happened to the last request for the server's channels — shown on the empty
    /// screen so "no channels" can be told apart from "switched off" or "not asked".
    enum JellyfinFetchState: Equatable {
        case notAsked, switchedOff, serverNotReady, answered(Int), failed(String)
    }
    @Published private(set) var jellyfinState: JellyfinFetchState = .notAsked
    /// Channel counts of the reduced queries tried after an empty answer ("n / n").
    @Published private(set) var probeSummary = ""
    /// Signed-in user and the server's own tuner / guide counts, read after an empty answer.
    @Published private(set) var serverFacts = ""
    var externalChannelCount: Int { externalAllowed ? store.visibleChannels.count : 0 }
    var externalSwitchedOn: Bool { externalAllowed }
    private var isFetchingJellyfin = false
    private weak var appState: AppState?
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Rebuild when external content or the source switches change (after the change lands).
        Publishers.Merge3(
            store.$contentVersion.map { _ in () },
            store.$channels.map { _ in () },
            Publishers.Merge(store.$showJellyfinChannels.map { _ in () }, store.$showExternalChannels.map { _ in () })
        )
        .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
        .sink { [weak self] in self?.rebuild() }
        .store(in: &cancellables)

        store.$showJellyfinChannels
            .dropFirst()
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let appState = self.appState, self.jellyfinChannels.isEmpty else { return }
                Task { await self.load(appState: appState) }
            }
            .store(in: &cancellables)

        // Tuners / guides were added to or removed from the server in Live TV Settings.
        // The server rescans in the background, so ask again now and once more a bit later.
        NotificationCenter.default.publisher(for: .liveTvServerSourcesChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { [weak self] in
                    await self?.reloadJellyfin()
                    try? await Task.sleep(for: .seconds(12))
                    await self?.reloadJellyfin()
                }
            }
            .store(in: &cancellables)
    }

    /// Fetches the server's channels again. They used to be read once per app launch, so
    /// channels added on the server afterwards (or a first answer that came back empty)
    /// left the screen on "No Channels" until the app was restarted.
    func reloadJellyfin() async {
        guard let appState else { jellyfinState = .notAsked; return }
        guard store.showJellyfinChannels else { jellyfinState = .switchedOff; return }
        guard appState.serverValidated, !appState.serverUnreachable else { jellyfinState = .serverNotReady; return }
        guard !isFetchingJellyfin else { return }
        isFetchingJellyfin = true
        defer { isFetchingJellyfin = false }
        serverURL = appState.serverURL
        do {
            jellyfinChannels = try await JellyfinAPI.shared.getLiveTvChannels(
                serverURL: appState.serverURL, userId: appState.userId, token: appState.token)
            jellyfinError = nil
            jellyfinState = .answered(jellyfinChannels.count)
            probeSummary = ""
            // The full query came back empty: ask again with fewer parameters. If a reduced
            // query returns channels, use them and record which one worked.
            if jellyfinChannels.isEmpty {
                var counts: [String] = []
                for variant in [1, 2] {
                    if let found = try? await JellyfinAPI.shared.getLiveTvChannelsProbe(
                        serverURL: appState.serverURL, userId: appState.userId, token: appState.token, variant: variant) {
                        counts.append("\(found.count)")
                        if !found.isEmpty && jellyfinChannels.isEmpty { jellyfinChannels = found }
                    } else {
                        counts.append("x")
                    }
                }
                probeSummary = counts.joined(separator: " / ")

                // What does this server itself say it has, and who is asking?
                var facts: [String] = [appState.username]
                if let admin = try? await JellyfinAPI.shared.currentUserIsAdministrator(
                    serverURL: appState.serverURL, token: appState.token) {
                    facts.append(admin ? "admin" : "user")
                }
                if let config = try? await JellyfinAPI.shared.getLiveTvServerConfig(
                    serverURL: appState.serverURL, token: appState.token) {
                    facts.append("tuner \(config.tunerHosts.count)")
                    facts.append("epg \(config.listingProviders.count)")
                } else {
                    facts.append("tuner ?")
                }
                serverFacts = facts.joined(separator: " · ")
            } else {
                serverFacts = ""
            }
        } catch {
            jellyfinError = error.localizedDescription
            jellyfinState = .failed(error.localizedDescription)
        }
        lastJellyfinFetch = Date()
        isLoading = false
        rebuild()
    }

    /// Called when the Live TV screen comes on screen: refresh if the last answer is old,
    /// and always when there is nothing to show.
    func refreshJellyfinIfStale() async {
        let age = Date().timeIntervalSince(lastJellyfinFetch)
        if jellyfinChannels.isEmpty ? age > 5 : age > 120 { await reloadJellyfin() }
    }

    /// External lists sit behind the same Pro lock as Live TV itself.
    private var externalAllowed: Bool {
        (appState?.isPro ?? AppState.shared?.isPro ?? false) && store.showExternalChannels
    }

    func load(appState: AppState) async {
        self.appState = appState
        serverURL = appState.serverURL

        if appState.isPro {
            await store.loadCacheIfNeeded()
            rebuild()
        }

        let serverReady = appState.serverValidated && !appState.serverUnreachable
        if store.showJellyfinChannels && serverReady {
            if channels.isEmpty { isLoading = true }
            error = nil
            do {
                jellyfinChannels = try await JellyfinAPI.shared.getLiveTvChannels(
                    serverURL: appState.serverURL, userId: appState.userId, token: appState.token
                )
                jellyfinError = nil
                jellyfinState = .answered(jellyfinChannels.count)
            } catch {
                jellyfinError = error.localizedDescription
                jellyfinState = .failed(error.localizedDescription)
            }
            lastJellyfinFetch = Date()
        } else if store.showJellyfinChannels && !serverReady && !externalAllowed {
            // Same as before: wait for the server check before showing anything.
            return
        }
        isLoading = false
        rebuild()

        if appState.isPro && appState.experimentalLiveTv {
            Task { await store.refreshIfDue() }
        }
    }

    func rebuild() {
        var list: [JellyfinItem] = []
        if store.showJellyfinChannels { list += jellyfinChannels }
        if externalAllowed { list += store.visibleItems() }
        channels = list
        error = list.isEmpty ? jellyfinError : nil
        // A filter that points at a source which is no longer on screen would hide every
        // remaining channel (and the filter bar with it), so drop it. This is what made the
        // Jellyfin channels "disappear" when external lists were switched off while an
        // external list was the selected filter.
        switch sourceFilter {
        case .all:
            break
        case .jellyfin:
            if !store.showJellyfinChannels || jellyfinChannels.isEmpty { sourceFilter = .all }
        case .external(let id):
            let stillShown = externalAllowed
                && store.playlists.contains(where: { $0.id == id && $0.isEnabled })
                && store.visibleChannels.contains(where: { $0.sourceId == id })
            if !stillShown { sourceFilter = .all }
        }
        if let group = groupFilter, !availableGroups.contains(group) { groupFilter = nil }
    }

    /// How many of the channels on screen belong to a source (shown on the filter chips).
    func channelCount(for filter: SourceFilter) -> Int {
        switch filter {
        case .all: return channels.count
        case .jellyfin: return channels.filter { !isExternal($0) }.count
        case .external(let id):
            return channels.filter { isExternal($0) && store.channel(forItemId: $0.id)?.sourceId == id }.count
        }
    }

    // MARK: Sources and groups

    func isExternal(_ channel: JellyfinItem) -> Bool { ExternalLiveTvID.isExternal(channel.id) }

    /// Short label of the source a channel comes from (list name, or "Jellyfin").
    func sourceLabel(for channel: JellyfinItem) -> String {
        if isExternal(channel) { return store.sourceName(forItemId: channel.id) ?? "M3U" }
        return "Jellyfin"
    }

    /// Every tile carries a small mark saying where the channel comes from.
    var showsSourceBadges: Bool { !availableSources.isEmpty }

    struct SourceOption: Identifiable {
        let filter: SourceFilter
        let title: String
        var id: SourceFilter { filter }
        var isExternal: Bool { if case .external = filter { return true } else { return false } }
        /// Server channels vs. channels from an external list.
        var icon: String { isExternal ? "list.bullet.rectangle" : "server.rack" }
    }

    var availableSources: [SourceOption] {
        var out: [SourceOption] = []
        if store.showJellyfinChannels && !jellyfinChannels.isEmpty { out.append(SourceOption(filter: .jellyfin, title: "Jellyfin")) }
        if externalAllowed {
            let present = Set(store.visibleChannels.map(\.sourceId))
            for p in store.playlists where p.isEnabled && present.contains(p.id) {
                out.append(SourceOption(filter: .external(p.id), title: p.name))
            }
        }
        return out
    }

    /// Groups of the selected external list (empty for "All" and Jellyfin).
    var availableGroups: [String] {
        guard case .external(let id) = sourceFilter else { return [] }
        return store.groups(for: id).filter { !$0.isEmpty && !store.isGroupHidden(id, $0) }
    }

    func matchesFilters(_ channel: JellyfinItem) -> Bool {
        switch sourceFilter {
        case .all:
            break
        case .jellyfin:
            if isExternal(channel) { return false }
        case .external(let id):
            guard isExternal(channel), store.channel(forItemId: channel.id)?.sourceId == id else { return false }
        }
        if let group = groupFilter {
            return store.groupName(forItemId: channel.id) == group
        }
        return true
    }

    // MARK: Favourites (Jellyfin on the server, external ones on this device)

    func setFavorite(_ channel: JellyfinItem, _ favorite: Bool) async {
        if isExternal(channel) {
            store.setFavorite(channel.id, favorite)
        } else if let appState {
            try? await JellyfinAPI.shared.setFavorite(
                serverURL: appState.serverURL, itemId: channel.id,
                userId: appState.userId, token: appState.token, isFavorite: favorite)
            if let idx = jellyfinChannels.firstIndex(where: { $0.id == channel.id }) {
                var updated = jellyfinChannels[idx]
                var ud = updated.userData ?? JellyfinUserData(playbackPositionTicks: nil, played: nil, isFavorite: nil, playCount: nil)
                ud.isFavorite = favorite
                updated.userData = ud
                jellyfinChannels[idx] = updated
            }
        }
        rebuild()
    }
}

extension Notification.Name {
    /// Posted after a tuner or guide provider was added to / removed from the Jellyfin server.
    static let liveTvServerSourcesChanged = Notification.Name("jellygo.liveTvServerSourcesChanged")
}
