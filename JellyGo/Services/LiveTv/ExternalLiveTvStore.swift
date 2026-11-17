import Foundation
import Combine

// MARK: - Identifiers and stored definitions

nonisolated enum ExternalLiveTvID {
    /// External channels travel through the app as `JellyfinItem`s whose id starts with this.
    static let prefix = "ext:"
    static func isExternal(_ id: String) -> Bool { id.hasPrefix(prefix) }
}

/// One M3U list on this device. The address itself lives in the Keychain, never here.
nonisolated struct ExternalPlaylistSource: Codable, Identifiable, Hashable, Sendable {
    enum Origin: String, Codable, Sendable { case remote, file }

    var id = UUID()
    var name: String
    var isEnabled = true
    var origin: Origin = .remote
    /// Original file name for imported lists (display only).
    var fileName: String?
    /// Sent when downloading the list and, unless a channel sets its own, when playing.
    var userAgent: String?
    /// Also read the guide addresses the list announces (`url-tvg` / `x-tvg-url`).
    var useEmbeddedGuide = true
    var lastRefresh: Date?
    var lastError: String?
    var channelCount = 0
    var skippedVOD = 0
}

/// One XMLTV guide address on this device (address in the Keychain).
nonisolated struct ExternalGuideSource: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var isEnabled = true
    var lastRefresh: Date?
    var lastError: String?
    var programCount = 0
}

nonisolated struct ExternalChannel: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var sourceId: UUID
    var info: M3UChannel
}

nonisolated struct ExternalChannelPlayback: Sendable {
    let url: URL
    let userAgent: String?
    let referrer: String?
}

private nonisolated struct PlaylistCache: Codable, Sendable {
    var channels: [M3UChannel]
    var epgURLs: [String]
    var savedAt: Date
}

private nonisolated struct GuideCache: Codable, Sendable {
    var guide: XMLTVResult
    var savedAt: Date
}

nonisolated enum ExternalLiveTvError: LocalizedError {
    case missingAddress
    case http(Int)
    case emptyPlaylist
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .missingAddress:
            return String(localized: "The address is missing. Edit the source and enter it again.", bundle: AppState.currentBundle)
        case .http(let code):
            return String(format: String(localized: "Server answered with HTTP %d", bundle: AppState.currentBundle), code)
        case .emptyPlaylist:
            return String(localized: "No live channels found in this list.", bundle: AppState.currentBundle)
        case .unreadableFile:
            return String(localized: "The file could not be read.", bundle: AppState.currentBundle)
        }
    }
}

// MARK: - Store

/// Device-side external Live TV: M3U lists, XMLTV guides, their caches and refresh, and the
/// per-channel preferences (hidden groups/channels, local favourites).
@MainActor
final class ExternalLiveTvStore: ObservableObject {
    static let shared = ExternalLiveTvStore()

    // Definitions
    @Published private(set) var playlists: [ExternalPlaylistSource] = []
    @Published private(set) var guides: [ExternalGuideSource] = []

    // Content
    /// Channels of enabled lists (hidden ones included; see `visibleChannels`).
    @Published private(set) var channels: [ExternalChannel] = []
    /// Bumped whenever programmes, the time offset or channel preferences change.
    @Published private(set) var contentVersion = 0
    @Published private(set) var isRefreshingPlaylists = false
    @Published private(set) var isRefreshingGuide = false
    @Published private(set) var lastGuideRefresh: Date?
    @Published private(set) var lastGuideError: String?
    @Published private(set) var guideProgrammeCount = 0
    @Published private(set) var matchedChannelCount = 0

    // Preferences
    @Published var showJellyfinChannels: Bool { didSet { defaults.set(showJellyfinChannels, forKey: Keys.showJellyfin) } }
    @Published var showExternalChannels: Bool { didSet { defaults.set(showExternalChannels, forKey: Keys.showExternal) } }
    /// 0 = only manual refresh.
    @Published var playlistRefreshHours: Int { didSet { defaults.set(playlistRefreshHours, forKey: Keys.playlistHours) } }
    @Published var guideRefreshHours: Int { didSet { defaults.set(guideRefreshHours, forKey: Keys.guideHours) } }
    /// Added to every guide time (for guides with a wrong zone).
    @Published var guideOffsetMinutes: Int {
        didSet { defaults.set(guideOffsetMinutes, forKey: Keys.offset); contentVersion += 1 }
    }
    @Published private(set) var hiddenGroups: Set<String>
    @Published private(set) var hiddenChannelIds: Set<String>
    @Published private(set) var favoriteIds: Set<String>

    private let defaults = UserDefaults.standard
    private var playlistCaches: [UUID: PlaylistCache] = [:]
    private var guide = XMLTVResult()
    private var programsByChannelId: [String: [EPGProgram]] = [:]
    private var channelsById: [String: ExternalChannel] = [:]
    private var didLoadCache = false
    private var loadTask: Task<Void, Never>?

    private enum Keys {
        static let playlists = "jellygo.liveTv.ext.playlists"
        static let guides = "jellygo.liveTv.ext.guides"
        static let showJellyfin = "jellygo.liveTv.showJellyfin"
        static let showExternal = "jellygo.liveTv.showExternal"
        static let playlistHours = "jellygo.liveTv.ext.playlistHours"
        static let guideHours = "jellygo.liveTv.ext.guideHours"
        static let offset = "jellygo.liveTv.ext.guideOffsetMinutes"
        static let hiddenGroups = "jellygo.liveTv.ext.hiddenGroups"
        static let hiddenChannels = "jellygo.liveTv.ext.hiddenChannels"
        static let favorites = "jellygo.liveTv.ext.favorites"
        static let lastGuideRefresh = "jellygo.liveTv.ext.lastGuideRefresh"
        static let lastGuideError = "jellygo.liveTv.ext.lastGuideError"
        static func playlistSecret(_ id: UUID) -> String { "jellygo.liveTv.playlist.\(id.uuidString)" }
        static func guideSecret(_ id: UUID) -> String { "jellygo.liveTv.guide.\(id.uuidString)" }
    }

    /// Refresh interval choices in hours (0 = manual only).
    static let refreshIntervals = [0, 6, 12, 24, 48]

    private init() {
        let d = UserDefaults.standard
        showJellyfinChannels = d.object(forKey: Keys.showJellyfin) as? Bool ?? true
        showExternalChannels = d.object(forKey: Keys.showExternal) as? Bool ?? true
        playlistRefreshHours = d.object(forKey: Keys.playlistHours) as? Int ?? 24
        guideRefreshHours = d.object(forKey: Keys.guideHours) as? Int ?? 12
        guideOffsetMinutes = d.integer(forKey: Keys.offset)
        hiddenGroups = Set(d.stringArray(forKey: Keys.hiddenGroups) ?? [])
        hiddenChannelIds = Set(d.stringArray(forKey: Keys.hiddenChannels) ?? [])
        favoriteIds = Set(d.stringArray(forKey: Keys.favorites) ?? [])
        lastGuideRefresh = d.object(forKey: Keys.lastGuideRefresh) as? Date
        lastGuideError = d.string(forKey: Keys.lastGuideError)
        if let data = d.data(forKey: Keys.playlists),
           let list = try? JSONDecoder().decode([ExternalPlaylistSource].self, from: data) { playlists = list }
        if let data = d.data(forKey: Keys.guides),
           let list = try? JSONDecoder().decode([ExternalGuideSource].self, from: data) { guides = list }
    }

    // MARK: Paths

    nonisolated private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LiveTvExternal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Imported files are user data, so they live in Application Support (not purged).
    nonisolated private static var importDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LiveTvImported", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated private static func playlistCacheURL(_ id: UUID) -> URL { cacheDirectory.appendingPathComponent("playlist-\(id.uuidString).json") }
    nonisolated private static var guideCacheURL: URL { cacheDirectory.appendingPathComponent("guide.json") }
    nonisolated private static func importedFileURL(_ id: UUID) -> URL { importDirectory.appendingPathComponent("\(id.uuidString).m3u") }

    // MARK: Secrets

    func playlistAddress(_ id: UUID) -> String? { KeychainService.shared.secret(forKey: Keys.playlistSecret(id)) }
    func guideAddress(_ id: UUID) -> String? { KeychainService.shared.secret(forKey: Keys.guideSecret(id)) }

    /// Masked address for display (credentials hidden).
    func maskedPlaylistAddress(_ id: UUID) -> String {
        if let p = playlists.first(where: { $0.id == id }), p.origin == .file { return p.fileName ?? "" }
        return playlistAddress(id).map(LiveTvURLMasker.mask) ?? ""
    }
    func maskedGuideAddress(_ id: UUID) -> String { guideAddress(id).map(LiveTvURLMasker.mask) ?? "" }

    // MARK: Cache

    /// Loads cached channels and guide once (off the main thread), so the Live TV tab can
    /// show something immediately; a refresh follows separately.
    func loadCacheIfNeeded() async {
        if didLoadCache { return }
        if let loadTask { await loadTask.value; return }
        let ids = playlists.map(\.id)
        let task = Task {
            let (caches, guideCache) = await Task.detached(priority: .userInitiated) { () -> ([UUID: PlaylistCache], GuideCache?) in
                var caches: [UUID: PlaylistCache] = [:]
                let dec = JSONDecoder()
                for id in ids {
                    if let data = try? Data(contentsOf: Self.playlistCacheURL(id)),
                       let c = try? dec.decode(PlaylistCache.self, from: data) { caches[id] = c }
                }
                var guideCache: GuideCache?
                if let data = try? Data(contentsOf: Self.guideCacheURL) {
                    guideCache = try? dec.decode(GuideCache.self, from: data)
                }
                return (caches, guideCache)
            }.value
            playlistCaches.merge(caches) { current, _ in current }
            if let guideCache { guide = guideCache.guide }
            didLoadCache = true
            rebuildChannels()
            await rematchGuide()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private static func writeCache<T: Encodable & Sendable>(_ value: T, to url: URL) async {
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }.value
    }

    // MARK: Refresh

    /// Refreshes lists / guide whose interval has passed (0 = manual only).
    func refreshIfDue() async {
        await loadCacheIfNeeded()
        let now = Date()
        var refreshedAny = false
        if playlistRefreshHours > 0 {
            for p in playlists where p.isEnabled {
                let due = p.lastRefresh.map { now.timeIntervalSince($0) > Double(playlistRefreshHours) * 3600 } ?? true
                if due || playlistCaches[p.id] == nil {
                    await refreshPlaylist(p.id, rematch: false)
                    refreshedAny = true
                }
            }
        }
        let guideDue = guideRefreshHours > 0
            && (lastGuideRefresh.map { now.timeIntervalSince($0) > Double(guideRefreshHours) * 3600 } ?? true)
        if (guideDue || refreshedAny) && hasGuideAddresses {
            await refreshGuide()
        } else if refreshedAny {
            await rematchGuide()
        }
    }

    /// "Refresh now": every enabled list, then the guide.
    func refreshAll() async {
        await loadCacheIfNeeded()
        for p in playlists where p.isEnabled {
            await refreshPlaylist(p.id, rematch: false)
        }
        await refreshGuide()
    }

    private var hasGuideAddresses: Bool { !guideAddressList().isEmpty }

    func refreshPlaylist(_ id: UUID, rematch: Bool = true) async {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let source = playlists[index]
        isRefreshingPlaylists = true
        defer { isRefreshingPlaylists = false }

        do {
            let data: Data
            switch source.origin {
            case .remote:
                guard let address = playlistAddress(id), let url = URL(string: address) else { throw ExternalLiveTvError.missingAddress }
                print("[LIVETV-EXT] refreshing list \(LiveTvURLMasker.mask(address))")
                data = try await Self.download(url, userAgent: source.userAgent)
            case .file:
                guard let d = try? Data(contentsOf: Self.importedFileURL(id)) else { throw ExternalLiveTvError.unreadableFile }
                data = d
            }
            let playlist = try await Task.detached(priority: .userInitiated) { () throws -> M3UPlaylist in
                let raw = Gzip.isGzip(data) ? try Gzip.decompress(data) : data
                return M3UParser.parse(data: raw)
            }.value
            guard !playlist.channels.isEmpty else { throw ExternalLiveTvError.emptyPlaylist }

            let cache = PlaylistCache(channels: playlist.channels, epgURLs: playlist.epgURLs, savedAt: Date())
            playlistCaches[id] = cache
            await Self.writeCache(cache, to: Self.playlistCacheURL(id))
            updatePlaylist(id) {
                $0.lastRefresh = Date()
                $0.lastError = nil
                $0.channelCount = playlist.channels.count
                $0.skippedVOD = playlist.skippedVOD
            }
            print("[LIVETV-EXT] list ok: \(playlist.channels.count) channels, \(playlist.skippedVOD) VOD skipped, \(playlist.malformedLines) malformed")
        } catch {
            print("[LIVETV-EXT] list failed: \(error.localizedDescription)")
            updatePlaylist(id) { $0.lastError = error.localizedDescription }
        }
        rebuildChannels()
        if rematch { await rematchGuide() }
    }

    /// All guide addresses to read: enabled guide sources, then guides announced by lists.
    private func guideAddressList() -> [(guideId: UUID?, address: String, userAgent: String?)] {
        var out: [(UUID?, String, String?)] = []
        var seen = Set<String>()
        for g in guides where g.isEnabled {
            if let a = guideAddress(g.id), seen.insert(a).inserted { out.append((g.id, a, nil)) }
        }
        for p in playlists where p.isEnabled && p.useEmbeddedGuide {
            for a in playlistCaches[p.id]?.epgURLs ?? [] where seen.insert(a).inserted {
                out.append((nil, a, p.userAgent))
            }
        }
        return out
    }

    func refreshGuide() async {
        guard !isRefreshingGuide else { return }
        isRefreshingGuide = true
        defer { isRefreshingGuide = false }

        let addresses = guideAddressList()
        guard !addresses.isEmpty, !channels.isEmpty else {
            if addresses.isEmpty { guide = XMLTVResult(); await Self.writeCache(GuideCache(guide: guide, savedAt: Date()), to: Self.guideCacheURL) }
            await rematchGuide()
            return
        }

        let now = Date()
        let filter = XMLTVFilter(
            wantedIds: Set(channels.compactMap { $0.info.tvgId?.lowercased() }),
            wantedNames: Set(channels.flatMap { [$0.info.name, $0.info.tvgName].compactMap { $0 } }
                .map(LiveTvNameMatcher.normalize).filter { !$0.isEmpty }),
            windowStart: now.addingTimeInterval(-2 * 3600),
            windowEnd: now.addingTimeInterval(36 * 3600))

        var merged = XMLTVResult()
        var errors: [String] = []
        var anySuccess = false
        for entry in addresses {
            guard let url = URL(string: entry.address) else { continue }
            print("[LIVETV-EXT] refreshing guide \(LiveTvURLMasker.mask(entry.address))")
            do {
                let result = try await Self.downloadAndParseGuide(url, filter: filter, userAgent: entry.userAgent)
                merged.merge(result)
                anySuccess = true
                if let gid = entry.guideId {
                    updateGuide(gid) { $0.lastRefresh = Date(); $0.lastError = nil; $0.programCount = result.keptProgrammes }
                }
                print("[LIVETV-EXT] guide ok: \(result.totalProgrammes) programmes read, \(result.keptProgrammes) kept")
            } catch {
                print("[LIVETV-EXT] guide failed: \(error.localizedDescription)")
                errors.append(error.localizedDescription)
                if let gid = entry.guideId { updateGuide(gid) { $0.lastError = error.localizedDescription } }
            }
        }

        if anySuccess {
            merged.finalize()
            guide = merged
            lastGuideRefresh = Date()
            defaults.set(lastGuideRefresh, forKey: Keys.lastGuideRefresh)
            await Self.writeCache(GuideCache(guide: merged, savedAt: Date()), to: Self.guideCacheURL)
        }
        // A failed refresh keeps the previous guide.
        lastGuideError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        defaults.set(lastGuideError, forKey: Keys.lastGuideError)
        await rematchGuide()
    }

    func clearGuideCache() {
        guide = XMLTVResult()
        programsByChannelId = [:]
        guideProgrammeCount = 0
        matchedChannelCount = 0
        lastGuideRefresh = nil
        lastGuideError = nil
        defaults.removeObject(forKey: Keys.lastGuideRefresh)
        defaults.removeObject(forKey: Keys.lastGuideError)
        try? FileManager.default.removeItem(at: Self.guideCacheURL)
        contentVersion += 1
    }

    // MARK: Network (no Jellyfin token ever goes here)

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 15 * 60
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private static func request(_ url: URL, userAgent: String?) -> URLRequest {
        var req = URLRequest(url: url)
        if let userAgent, !userAgent.isEmpty { req.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        return req
    }

    private static func download(_ url: URL, userAgent: String?) async throws -> Data {
        let (data, response) = try await session.data(for: request(url, userAgent: userAgent))
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ExternalLiveTvError.http(http.statusCode)
        }
        return data
    }

    /// Downloads to a file, inflates gzip to a second file if needed, then streams the XML.
    private static func downloadAndParseGuide(_ url: URL, filter: XMLTVFilter, userAgent: String?) async throws -> XMLTVResult {
        let (tempURL, response) = try await session.download(for: request(url, userAgent: userAgent))
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("guide-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: tempURL, to: work)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: work)
            throw ExternalLiveTvError.http(http.statusCode)
        }
        return try await Task.detached(priority: .utility) { () throws -> XMLTVResult in
            var xmlURL = work
            defer {
                try? FileManager.default.removeItem(at: work)
                if xmlURL != work { try? FileManager.default.removeItem(at: xmlURL) }
            }
            if Gzip.isGzipFile(work) {
                xmlURL = work.appendingPathExtension("xml")
                try Gzip.decompressFile(at: work, to: xmlURL)
            }
            let (result, error) = XMLTVParser.parse(fileURL: xmlURL, filter: filter)
            if let error { throw error }
            return result
        }.value
    }

    // MARK: Channels and guide matching

    private func rebuildChannels() {
        var list: [ExternalChannel] = []
        for p in playlists where p.isEnabled {
            guard let cache = playlistCaches[p.id] else { continue }
            let prefix = String(p.id.uuidString.prefix(8)).lowercased()
            var seen = [String: Int]()
            for ch in cache.channels {
                var key = LiveTvNameMatcher.stableHash("\(ch.name)|\(ch.tvgId ?? "")|\(ch.groupTitle ?? "")")
                let n = seen[key, default: 0]
                seen[key] = n + 1
                if n > 0 { key += "-\(n)" }
                list.append(ExternalChannel(id: "\(ExternalLiveTvID.prefix)\(prefix):\(key)", sourceId: p.id, info: ch))
            }
        }
        channels = list
        channelsById = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func rematchGuide() async {
        let chans = channels
        let g = guide
        let cutoff = Date().addingTimeInterval(-2 * 3600)
        let matched = await Task.detached(priority: .userInitiated) { () -> [String: [EPGProgram]] in
            let index = EPGMatcher.nameIndex(for: g)
            var out: [String: [EPGProgram]] = [:]
            for ch in chans {
                guard let key = EPGMatcher.guideKey(for: ch.info, guide: g, nameIndex: index),
                      let progs = g.programsByChannel[key] else { continue }
                let current = progs.filter { $0.stop > cutoff }
                if !current.isEmpty { out[ch.id] = current }
            }
            return out
        }.value
        programsByChannelId = matched
        matchedChannelCount = matched.count
        guideProgrammeCount = g.keptProgrammes
        contentVersion += 1
    }

    // MARK: Lookups used by the Live TV screen and the player

    func channel(forItemId id: String) -> ExternalChannel? {
        channelsById[id]
    }

    func playback(forItemId id: String) -> ExternalChannelPlayback? {
        guard let ch = channel(forItemId: id), let url = URL(string: ch.info.url) else { return nil }
        let sourceUA = playlists.first { $0.id == ch.sourceId }?.userAgent
        return ExternalChannelPlayback(url: url,
                                       userAgent: ch.info.userAgent ?? sourceUA,
                                       referrer: ch.info.referrer)
    }

    func logoURL(forItemId id: String) -> URL? {
        guard let logo = channel(forItemId: id)?.info.tvgLogo else { return nil }
        return URL(string: logo)
    }

    func sourceName(forItemId id: String) -> String? {
        guard let ch = channel(forItemId: id) else { return nil }
        return playlists.first { $0.id == ch.sourceId }?.name
    }

    func groupName(forItemId id: String) -> String? {
        channel(forItemId: id)?.info.groupTitle
    }

    /// Guide entries with the user's time offset applied.
    func programs(forChannelId id: String) -> [EPGProgram] {
        let offset = TimeInterval(guideOffsetMinutes * 60)
        return (programsByChannelId[id] ?? []).map {
            var p = $0
            p.start += offset
            p.stop += offset
            return p
        }
    }

    func currentProgram(forChannelId id: String, at now: Date = Date()) -> EPGProgram? {
        let offset = TimeInterval(guideOffsetMinutes * 60)
        guard var p = programsByChannelId[id]?.first(where: { $0.start + offset <= now && now < $0.stop + offset }) else { return nil }
        p.start += offset
        p.stop += offset
        return p
    }

    private static func groupKey(_ sourceId: UUID, _ group: String) -> String { "\(sourceId.uuidString)|\(group)" }

    func groups(for sourceId: UUID) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for ch in channels where ch.sourceId == sourceId {
            let g = ch.info.groupTitle ?? ""
            if seen.insert(g).inserted { out.append(g) }
        }
        return out
    }

    func isGroupHidden(_ sourceId: UUID, _ group: String) -> Bool { hiddenGroups.contains(Self.groupKey(sourceId, group)) }

    func setGroupHidden(_ sourceId: UUID, _ group: String, hidden: Bool) {
        let key = Self.groupKey(sourceId, group)
        if hidden { hiddenGroups.insert(key) } else { hiddenGroups.remove(key) }
        defaults.set(Array(hiddenGroups), forKey: Keys.hiddenGroups)
        contentVersion += 1
    }

    func isChannelHidden(_ id: String) -> Bool { hiddenChannelIds.contains(id) }

    func setChannelHidden(_ id: String, hidden: Bool) {
        if hidden { hiddenChannelIds.insert(id) } else { hiddenChannelIds.remove(id) }
        defaults.set(Array(hiddenChannelIds), forKey: Keys.hiddenChannels)
        contentVersion += 1
    }

    func isFavorite(_ id: String) -> Bool { favoriteIds.contains(id) }

    func setFavorite(_ id: String, _ favorite: Bool) {
        if favorite { favoriteIds.insert(id) } else { favoriteIds.remove(id) }
        defaults.set(Array(favoriteIds), forKey: Keys.favorites)
    }

    /// Channels to show: enabled lists, minus hidden groups and hidden channels.
    var visibleChannels: [ExternalChannel] {
        channels.filter { ch in
            !hiddenChannelIds.contains(ch.id)
                && !hiddenGroups.contains(Self.groupKey(ch.sourceId, ch.info.groupTitle ?? ""))
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// External channels as `JellyfinItem`s (type `TvChannel`), so the existing tiles,
    /// favourites filter, search and player keep working unchanged.
    func visibleItems(now: Date = Date()) -> [JellyfinItem] {
        visibleChannels.map { item(for: $0, now: now) }
    }

    func item(for ch: ExternalChannel, now: Date = Date()) -> JellyfinItem {
        var program: JellyfinProgram?
        if let p = currentProgram(forChannelId: ch.id, at: now) {
            program = JellyfinProgram(
                id: "\(ch.id):\(Int(p.start.timeIntervalSince1970))",
                name: p.title,
                overview: p.desc,
                startDate: Self.isoFormatter.string(from: p.start),
                endDate: Self.isoFormatter.string(from: p.stop),
                episodeTitle: p.subtitle,
                channelId: ch.id)
        }
        return JellyfinItem(
            id: ch.id, name: ch.info.name, type: "TvChannel",
            overview: nil, productionYear: nil, communityRating: nil, criticRating: nil,
            runTimeTicks: nil, seriesName: nil, seriesId: nil, seasonName: nil,
            indexNumber: nil, parentIndexNumber: nil,
            userData: JellyfinUserData(playbackPositionTicks: nil, played: nil,
                                       isFavorite: favoriteIds.contains(ch.id), playCount: nil),
            imageBlurHashes: nil, primaryImageAspectRatio: nil, genres: nil, officialRating: nil,
            taglines: nil, people: nil, premiereDate: nil, mediaStreams: nil, mediaSources: nil,
            childCount: nil, providerIds: nil, endDate: nil, productionLocations: nil,
            imageTags: nil, backdropImageTags: nil,
            channelNumber: ch.info.channelNumber, currentProgram: program)
    }

    // MARK: Editing lists

    private func persistPlaylists() {
        if let data = try? JSONEncoder().encode(playlists) { defaults.set(data, forKey: Keys.playlists) }
    }

    private func persistGuides() {
        if let data = try? JSONEncoder().encode(guides) { defaults.set(data, forKey: Keys.guides) }
    }

    private func updatePlaylist(_ id: UUID, _ change: (inout ExternalPlaylistSource) -> Void) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        change(&playlists[i])
        persistPlaylists()
    }

    private func updateGuide(_ id: UUID, _ change: (inout ExternalGuideSource) -> Void) {
        guard let i = guides.firstIndex(where: { $0.id == id }) else { return }
        change(&guides[i])
        persistGuides()
    }

    @discardableResult
    func addPlaylist(name: String, address: String, userAgent: String?, useEmbeddedGuide: Bool) -> UUID {
        let source = ExternalPlaylistSource(name: name, userAgent: userAgent?.nilIfBlank, useEmbeddedGuide: useEmbeddedGuide)
        KeychainService.shared.saveSecret(address, forKey: Keys.playlistSecret(source.id))
        playlists.append(source)
        persistPlaylists()
        return source.id
    }

    /// Copies a file picked in Files into the app, so it stays readable later.
    @discardableResult
    func importPlaylist(name: String, from fileURL: URL, userAgent: String?, useEmbeddedGuide: Bool) throws -> UUID {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: fileURL) else { throw ExternalLiveTvError.unreadableFile }
        let source = ExternalPlaylistSource(name: name, origin: .file, fileName: fileURL.lastPathComponent,
                                            userAgent: userAgent?.nilIfBlank, useEmbeddedGuide: useEmbeddedGuide)
        try data.write(to: Self.importedFileURL(source.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        playlists.append(source)
        persistPlaylists()
        return source.id
    }

    /// `address == nil` keeps the stored address.
    func editPlaylist(_ id: UUID, name: String, address: String?, userAgent: String?, useEmbeddedGuide: Bool) {
        if let address { KeychainService.shared.saveSecret(address, forKey: Keys.playlistSecret(id)) }
        updatePlaylist(id) {
            $0.name = name
            $0.userAgent = userAgent?.nilIfBlank
            $0.useEmbeddedGuide = useEmbeddedGuide
        }
    }

    func setPlaylistEnabled(_ id: UUID, _ enabled: Bool) {
        updatePlaylist(id) { $0.isEnabled = enabled }
        rebuildChannels()
        Task { await rematchGuide() }
    }

    func deletePlaylist(_ id: UUID) {
        KeychainService.shared.deleteSecret(forKey: Keys.playlistSecret(id))
        try? FileManager.default.removeItem(at: Self.playlistCacheURL(id))
        try? FileManager.default.removeItem(at: Self.importedFileURL(id))
        playlistCaches[id] = nil
        playlists.removeAll { $0.id == id }
        persistPlaylists()
        let prefix = "\(id.uuidString)|"
        hiddenGroups = hiddenGroups.filter { !$0.hasPrefix(prefix) }
        defaults.set(Array(hiddenGroups), forKey: Keys.hiddenGroups)
        rebuildChannels()
        Task { await rematchGuide() }
    }

    @discardableResult
    func addGuide(name: String, address: String) -> UUID {
        let source = ExternalGuideSource(name: name)
        KeychainService.shared.saveSecret(address, forKey: Keys.guideSecret(source.id))
        guides.append(source)
        persistGuides()
        return source.id
    }

    func editGuide(_ id: UUID, name: String, address: String?) {
        if let address { KeychainService.shared.saveSecret(address, forKey: Keys.guideSecret(id)) }
        updateGuide(id) { $0.name = name }
    }

    func setGuideEnabled(_ id: UUID, _ enabled: Bool) {
        updateGuide(id) { $0.isEnabled = enabled }
    }

    func deleteGuide(_ id: UUID) {
        KeychainService.shared.deleteSecret(forKey: Keys.guideSecret(id))
        guides.removeAll { $0.id == id }
        persistGuides()
    }

    /// Guide addresses announced by a list (for display in the list editor).
    func embeddedGuideCount(_ id: UUID) -> Int { playlistCaches[id]?.epgURLs.count ?? 0 }

    func channels(for sourceId: UUID) -> [ExternalChannel] {
        channels.filter { $0.sourceId == sourceId }
    }
}

private extension String {
    nonisolated var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Channel artwork for both kinds of channel: Jellyfin image API for server channels,
/// the list's `tvg-logo` for external ones (plain request, no Jellyfin token).
enum LiveTvChannelArt {
    static func logoURL(for channel: JellyfinItem, serverURL: String, maxWidth: Int) -> URL? {
        if ExternalLiveTvID.isExternal(channel.id) {
            return ExternalLiveTvStore.shared.logoURL(forItemId: channel.id)
        }
        return JellyfinAPI.shared.imageURL(serverURL: serverURL, itemId: channel.id, imageType: "Primary", maxWidth: maxWidth)
    }
}
